use Test2::V0;
use Config;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use File::Spec ();
use POSIX qw/WNOHANG/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers/;
use Test2::Harness2::Test::ResourceService qw//;

# The jump_to subtest drives the interpose path with a stub ipcm_info; the
# collector would otherwise try to talk to a real IPC bus on startup and
# leak send-failure warnings onto STDERR. Stubbing the handle class keeps
# the unit test clean. Inherited through fork into the service and
# collector processes.
BEGIN {
    require IPC::Manager;
    no warnings 'once', 'redefine';
    *IPC::Manager::connect = sub {
        return bless {}, 'T2H2_Harness2Test_NoopClient';
    };
    *T2H2_Harness2Test_NoopClient::send_message = sub { return };
    *T2H2_Harness2Test_NoopClient::peer_active  = sub { 1 };
    *T2H2_Harness2Test_NoopClient::disconnect   = sub { return };
}

use Test2::Harness2;
use Test2::Harness2::Run::State;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Run;

my $CAN_FORK = $Config{d_fork};

# Wrap a path (or list of paths) in TestFile objects so the scheduler
# and Run->from_files see the object-only input they now require.
sub _tf  { Test2::Harness2::TestFile->new(file => $_[0]) }
sub _tfs { [map { _tf($_) } @_] }

# Inline test resources for the restart and per-run subtests.
# Test::Restart::Res pairs a resource with a lazily-built throwaway
# service class (built via Test::ResourceService) whose spawn() pulls
# one pid per call from the resource's own PIDS queue. Tests tweak
# knobs on the resource (restartable_flag / die_on_start) to shape the
# generated class. A resource that never declares services (no pids
# set) reports no services(), which is what the broken_resource_*
# subtests want.
{

    package Test::Restart::Res;
    use Object::HashBase qw{
        <pids
        +broken
        +permanent_broken
        +paused
        <die_on_start
        <restartable_flag
        +service_class
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';
    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub is_broken           { $_[0]->{+BROKEN}           ? 1 : 0 }
    sub is_permanent_broken { $_[0]->{+PERMANENT_BROKEN} ? 1 : 0 }
    sub is_paused           { $_[0]->{+PAUSED}           ? 1 : 0 }

    sub mark_broken { $_[0]->{+BROKEN} = 1 }

    sub mark_permanent_broken {
        my $self = shift;
        $self->{+PERMANENT_BROKEN} = 1;
        $self->{+BROKEN}           = 1;
    }
    sub mark_paused { $_[0]->{+PAUSED} = 1 }

    sub mark_resumed {
        my $self = shift;
        $self->{+BROKEN} = 0;
        $self->{+PAUSED} = 0;
    }

    sub service_class {
        my $self = shift;
        return $self->{+SERVICE_CLASS} //= Test2::Harness2::Test::ResourceService::make_service_class(
            restartable => defined $self->{+RESTARTABLE_FLAG} ? $self->{+RESTARTABLE_FLAG} : 1,
            pids        => $self->{+PIDS},
            ($self->{+DIE_ON_START} ? (spawn_die => "service_foo_start failure (test)") : ()),
        );
    }

    sub services {
        my $self = shift;
        my $pids = $self->{+PIDS} // [];
        # No services unless the resource was primed with a pid queue.
        return () unless @$pids;
        return ([$self->service_class, name => 'foo']);
    }
}

# Per-run resource-service lifecycle (invocation of service_* methods,
# teardown calls) lives in the run-service process after the harness
# refactor; those tests live in t/unit/Harness2/RunService.t. Here we
# only exercise the harness's scheduling-side handling of per-run
# resources and the lazy spawn of the run service itself.

# Minimal IPC message stub for run_on_general_message subtests. Real
# IPC messages have a content() accessor; we only need that much.
{

    package Test::FakeIpcMsg;
    sub new     { my ($c, $body) = @_; bless {body => $body}, $c }
    sub content { $_[0]->{body} }
}

subtest 'constructs with valid workdir' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    is($h->workdir, $dir,      'workdir stored');
    is($h->name,    'harness', 'name defaults to "harness"');
    like($h->job_id, qr/^[0-9A-F-]{36}$/i, 'job_id auto-generated');
    ok(-d "$dir/logs/services", 'logs/services/ dir created');
};

subtest 'rejects non-empty logs/ directory but accepts an empty one' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/logs");
    open my $fh, '>', "$dir/logs/stale.jsonl" or die $!;
    close $fh;

    my $ok  = eval { Test2::Harness2->new(workdir => $dir); 1 };
    my $err = $@;
    ok(!$ok, 'constructor dies when logs/ has leftover content');
    like($err, qr/not empty/, 'error explains what is wrong');

    # An empty existing logs/ directory should be accepted.
    my $dir2 = tempdir(CLEANUP => 1);
    make_path("$dir2/logs");
    my $h = eval { Test2::Harness2->new(workdir => $dir2) };
    ok($h,                       'empty existing logs/ dir is accepted') or diag $@;
    ok(-d "$dir2/logs/services", 'services subdir created under the empty logs/');
};

subtest 'logdir attribute accepts absolute and relative paths' => sub {
    my $wd  = tempdir(CLEANUP => 1);
    my $alt = tempdir(CLEANUP => 1);

    my $h = Test2::Harness2->new(workdir => $wd, logdir => $alt);
    is($h->logdir, $alt, 'absolute logdir used verbatim');
    ok(-d "$alt/services", 'services subdir created in absolute logdir');

    my $wd2 = tempdir(CLEANUP => 1);
    my $h2  = Test2::Harness2->new(workdir => $wd2, logdir => 'custom-logs');
    is(
        $h2->logdir, File::Spec->catdir($wd2, 'custom-logs'),
        'relative logdir is resolved under workdir'
    );
    ok(-d "$wd2/custom-logs/services", 'services subdir created under relative logdir');
};

subtest 'tolerates other files in workdir' => sub {
    my $dir = tempdir(CLEANUP => 1);
    open my $fh, '>', "$dir/some-other-file.txt" or die;
    close $fh;
    my $ok = eval { Test2::Harness2->new(workdir => $dir); 1 };
    ok($ok, 'unrelated files are fine') or diag $@;
};

subtest 'workdir is required' => sub {
    my $ok = eval { Test2::Harness2->new; 1 };
    ok(!$ok, 'workdir is required');
};

subtest 'consumes IPC::Manager::Role::Service' => sub {
    ok(Test2::Harness2->DOES('IPC::Manager::Role::Service'), 'role applied');
};

subtest 'status returns current state without running' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # The harness no longer auto-injects a JobCount; pass one explicitly
    # so this test can still observe the resource list surfaces in
    # status output.
    my $h = Test2::Harness2->new(
        workdir   => $dir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 1)],
    );

    my $status = $h->request_handler_status;

    is($status->{service}{name},    'harness');
    is($status->{service}{pid},     $$);
    is($status->{service}{workdir}, $dir);
    is($status->{service}{state},   'running');
    like($status->{service}{job_id}, qr/^[0-9A-F-]{36}$/i);
    is($status->{queue},                  [],         'empty queue');
    is($status->{running},                [],         'nothing running');
    is(scalar @{$status->{resources}},    1,          'explicit JobCount resource surfaces');
    is($status->{resources}[0]{resource}, 'jobcount', 'resource name surfaces');
};

subtest 'no resources by default (unlimited concurrency)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $status = $h->request_handler_status;
    is($status->{resources}, [], 'resources is empty when caller did not provide any');
};

subtest 'queue_test_run enqueues and returns run_id' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({files => _tfs('t/a.t', 't/b.t')});
    ok($res->{ok}, 'accepted');
    is($res->{run_id}, 1, 'first run gets ord 1');

    my $status = $h->request_handler_status;
    is(scalar @{$status->{queue}},             1,              'one run queued');
    is($status->{queue}[0]{run_id},            $res->{run_id}, 'matches returned id');
    is(scalar @{$status->{queue}[0]{pending}}, 2,              'two pending jobs');

    my $res2 = $h->request_handler_queue_test_run({files => _tfs('t/c.t')});
    is($res2->{run_id}, 2, 'second run gets ord 2');
};

subtest 'queue_test_run rejects caller-supplied run_id (harness owns ord allocation)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my $res = $h->request_handler_queue_test_run({files => _tfs('t/x.t'), run_id => 'my-id'});
    ok(!$res->{ok}, 'rejected');
    like($res->{error}, qr/run_id/);
};

subtest 'queue_test_run does not write the runs/<id>.json snapshot (run service does)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({files => _tfs('t/x.t')});
    ok($res->{ok}, 'queued');

    my $path = "$dir/logs/runs/$res->{run_id}.json";
    ok(!-e $path, 'no snapshot at queue time -- run service owns the file');
};

subtest 'queue_test_run emits run_queued only (job_queued moved to run service)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::emit_service_event = sub {
        my ($self, %fields) = @_;
        push @emitted => \%fields;
    };

    $h->request_handler_queue_test_run({files => _tfs('t/x.t', 't/y.t')});

    is(scalar @emitted,   1,            'exactly one event emitted');
    is($emitted[0]{kind}, 'run_queued', 'event is run_queued');
    ok(defined $emitted[0]{run_id},           'run_queued has flat run_id');
    ok(defined $emitted[0]{queued_at},        'run_queued has flat queued_at');
    is(ref $emitted[0]{job_ids}, 'ARRAY',     'run_queued has flat job_ids array');
    is(scalar @{$emitted[0]{job_ids}}, 2,     'job_ids has one entry per file');
    ok($emitted[0]{run_data},                'run_queued still carries run_data');
    ok($emitted[0]{run_data}{jobs},           'run_data inlines jobs');
};

subtest 'queue_test_run rejects when state is not running' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->{state} = 'finishing';
    my $res = $h->request_handler_queue_test_run({files => _tfs('t/x.t')});
    ok(!$res->{ok}, 'rejected');
    like($res->{error}, qr/not accepting/);
};

subtest 'finish transitions running -> finishing and rejects further queueing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_finish;
    ok($res->{ok}, 'finish accepted');
    is($h->{state}, 'finishing', 'state transitioned');

    my $q = $h->request_handler_queue_test_run({files => _tfs('t/x.t')});
    ok(!$q->{ok}, 'subsequent queue rejected');

    my $again = $h->request_handler_finish;
    ok(!$again->{ok}, 'second finish returns ok=0');
};

subtest 'Terminate is idempotent and always accepted' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $r1 = $h->request_handler_terminate;
    ok($r1->{ok}, 'first accepted');
    is($h->{state}, 'terminating');

    my $r2 = $h->request_handler_terminate;
    ok($r2->{ok}, 'second still accepted');
};

subtest 'Detach removes a pid from watch_pids' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, parent_pids => [1001, 1002]);

    is($h->watch_pids, [1001, 1002]);

    my $res = $h->request_handler_detach({pid => 1001});
    ok($res->{ok});
    is($h->watch_pids, [1002], 'pid removed');

    # Idempotent: detaching an already-absent pid is also ok=1
    my $r2 = $h->request_handler_detach({pid => 1001});
    ok($r2->{ok});
    is($h->watch_pids, [1002]);
};

subtest 'run_on_all spawns the Collector directly (no run-service IPC)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(
        workdir   => $dir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 1)],
    );

    $h->request_handler_queue_test_run({files => _tfs('/abs/path/does-not-matter.t')});

    # The harness now calls _spawn_collector_for_job directly instead of
    # round-tripping through RunService via IPC. Stub the spawn at that
    # method boundary and capture the call args so we can assert the
    # right fields (env, run_id, job_id, test_file, etc.) reach the
    # collector.
    my @spawn_calls;
    {
        no warnings 'redefine';
        local *Test2::Harness2::RunService::spawn = sub { 90_000 };
        local *Test2::Harness2::_spawn_collector_for_job = sub {
            my ($self, $run, $job, %opts) = @_;
            push @spawn_calls => {
                run_id   => $run->run_id,
                job_id   => $job->job_id,
                job_try  => $job->job_try,
                test_file => $job->test_file_abs,
                env       => {%{$opts{env} // {}}},
                launch    => $opts{launch},
            };
            return {ok => 1, pid => 98765};
        };

        $h->{ipcm_info} = {fake => 1};    # enables _ensure_run_service_started fork path

        $h->run_on_all({});
    }

    is(scalar @spawn_calls, 1, 'exactly one collector spawn issued');
    my $call = $spawn_calls[0];
    is($call->{test_file}, '/abs/path/does-not-matter.t', 'test_file is absolute');
    is(
        $call->{env}{T2_HARNESS_MY_JOB_CONCURRENCY}, 1,
        'JobCount concurrency env var propagated via env',
    );
    is($call->{run_id}, 1, 'run_id passed through');
    is($call->{job_id}, 1, 'job_id passed through');
    is($call->{job_try}, 1, 'job_try 1 passed through');

    my @running = values %{$h->job_tracker->running_jobs};
    is(scalar @running,    1,     'one running job tracked');
    is($running[0]->{pid}, 98765, 'running job pid comes from spawn response');
};

subtest 'run_on_all commits no resource when any is unavailable' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Two resources: A has room, B is paused (available returns 0). A job must
    # not consume a slot on A when B would defer it.
    my $res_a = Test2::Harness2::Resource::JobCount->new(slots => 5);
    my $res_b = Test2::Harness2::Resource::JobCount->new(slots => 2);
    $res_b->mark_paused;

    my $h = Test2::Harness2->new(
        workdir   => $dir,
        resources => [$res_a, $res_b],
    );

    $h->request_handler_queue_test_run({files => _tfs('x.t')});

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub {
            die "must not spawn when a resource defers";
        };
        $h->run_on_all({});
    }

    is($res_a->used,                      0, 'resource A not committed when B defers');
    is($res_b->used,                      0, 'resource B not committed');
    is(scalar keys %{$h->job_tracker->running_jobs}, 0, 'no running jobs');
    is(scalar @{$h->scheduler->queue},             1, 'run still queued, job still pending');
};

subtest 'test_job_completed + job_release advance the harness scheduler' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(
        workdir   => $dir,
        resources => [Test2::Harness2::Resource::JobCount->new(slots => 1)],
    );

    $h->request_handler_queue_test_run({files => _tfs('/abs/dummy.t')});

    my $run    = $h->scheduler->queue->[0];
    my $rstate = $h->{run_states}->state($run->run_id);
    my $job_id = $rstate->pending->[0];
    my ($job)  = grep { $_->job_id eq $job_id } @{$run->jobs};
    $rstate->mark_running($job_id);

    my ($res) = @{$h->{resources}};
    my %env;
    $res->assign(id => 'test-assign', job => $job, env => \%env);

    $h->job_tracker->running_jobs->{$job_id} = {
        run                => $run,
        job                => $job,
        pid                => 91234,
        started_at         => time,
        assign_id          => 'test-assign',
        assigned_resources => [$res],
    };

    # test_job_completed mutates Run::State directly (Stage 4 of the
    # flatten): pending/running/done transitions land here.
    $h->run_on_general_message(
        Test::FakeIpcMsg->new({
            kind       => 'test_job_completed',
            run_id     => $run->run_id,
            job_id     => $job_id,
            pass       => 1,
            pass_count => 1,
            fail_count => 0,
            stamp      => time,
        }),
    );

    is(scalar @{$rstate->done},    1, 'Run::State marks job done after test_job_completed');
    is(scalar @{$rstate->running}, 0, 'Run::State clears running after test_job_completed');

    # job_release does the resource + RUNNING_JOBS cleanup. The
    # auditor sends both messages.
    $h->run_on_general_message(
        Test::FakeIpcMsg->new({
            kind   => 'job_release',
            run_id => $run->run_id,
            job_id => $job_id,
        }),
    );

    ok(!keys %{$h->job_tracker->running_jobs}, 'running_jobs cleared after job_release');
    is($res->used, 0, 'JobCount slot released');
};

subtest 'run_on_all emits run_started for the first job; no job_started' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    $h->request_handler_queue_test_run({files => _tfs('/abs/first.t')});

    $h->{ipcm_info} = {fake => 1};    # enable _ensure_run_service_started

    my @emitted;
    my $fake_ipc_handle = bless {
        ready => 1,
        sync  => sub { +{response => {ok => 1, pid => 123}} },
        },
        'Test::FakeIPCHandle';

    {
        no warnings 'redefine';
        local *Test::FakeIPCHandle::ready                   = sub { 1 };
        local *Test::FakeIPCHandle::sync_request            = sub { my $s = shift; $s->{sync}->(@_); };
        local *Test2::Harness2::RunService::spawn           = sub { 90_000 };
        local *Test2::Harness2::_run_service_handle         = sub { $fake_ipc_handle };
        local *Test2::Harness2::_wait_for_run_service_ready = sub { $fake_ipc_handle };
        local *Test2::Harness2::emit_service_event          = sub {
            my ($self, %fields) = @_;
            push @emitted => \%fields;
        };
        $h->run_on_all({});
    }

    my @kinds = map { $_->{kind} } @emitted;
    ok((grep { $_ eq 'run_started' } @kinds),  'run_started emitted');
    ok(!(grep { $_ eq 'job_started' } @kinds), 'job_started NOT emitted (run service owns it)');
    ok(!(grep { $_ eq 'job_queued' } @kinds),  'job_queued NOT emitted (run service owns it)');

    my ($rs) = grep { $_->{kind} eq 'run_started' } @emitted;
    is($rs->{run_id},     $h->scheduler->queue->[0]->run_id, 'run_started carries run_id flat');
    ok(defined $rs->{started_at}, 'run_started carries started_at');
};

subtest 'test_job_completed for the last running job triggers run_ended' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $run = Test2::Harness2::Run->from_files(run_id => 1, files => _tfs('/abs/done.t'));
    push @{$h->scheduler->queue} => $run;
    my ($job) = @{$run->jobs};
    my $rstate = Test2::Harness2::Run::State->new(
        run_id  => $run->run_id,
        pending => [map { $_->job_id } @{$run->jobs}],
    );
    $h->{run_states}->set_state($run->run_id, $rstate);
    $rstate->mark_running($job->job_id);
    $h->scheduler->queue_run($run);
    $h->scheduler->mark_running($run->run_id, $job->job_id);

    $h->job_tracker->running_jobs->{$job->job_id} = {
        run        => $run,
        job        => $job,
        pid        => 1,
        started_at => time,
    };

    my @emitted;
    no warnings 'redefine';
    local *Test2::Harness2::emit_service_event    = sub { push @emitted => {@_[1 .. $#_]} };
    local *Test2::Harness2::_teardown_run_service = sub { };

    $h->run_on_general_message(
        Test::FakeIpcMsg->new({
            kind       => 'test_job_completed',
            run_id     => $run->run_id,
            job_id     => $job->job_id,
            pass       => 1,
            pass_count => 1,
            fail_count => 0,
            stamp      => time,
        }),
    );
    # job_release closes out RUNNING_JOBS so the scheduler also says done.
    $h->run_on_general_message(
        Test::FakeIpcMsg->new({
            kind   => 'job_release',
            run_id => $run->run_id,
            job_id => $job->job_id,
        }),
    );

    my @kinds = map { $_->{kind} } @emitted;
    ok((grep { $_ eq 'job_completed' } @kinds), 'job_completed emitted by harness');
    ok((grep { $_ eq 'run_ended'     } @kinds), 'run_ended emitted on finalize');
};

subtest 'perform_hard_stop TERMs tracked pids and reaps them' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    # Fork a child that will wait for a signal.
    my $child_pid = fork // die "fork: $!";
    if (!$child_pid) {
        POSIX::setpgid(0, 0);    # simulate a test in its own pgroup
        $SIG{TERM} = sub { POSIX::_exit(0) };
        sleep 30;
        POSIX::_exit(99);
    }

    my $fake_handle = bless {pid => $child_pid}, 'Test2::Harness2::Collector::Handle';

    my $run    = Test2::Harness2::Run->from_files(run_id => 1, files => _tfs('dummy.t'));
    my ($job)  = @{$run->jobs};
    my $job_id = $job->job_id;
    my $rstate = Test2::Harness2::Run::State->new(
        run_id  => $run->run_id,
        pending => [$job_id],
    );
    $h->{run_states}->set_state($run->run_id, $rstate);
    $rstate->mark_running($job_id);

    $h->job_tracker->running_jobs->{$job_id} = {
        run                => $run,
        job                => $job,
        handle             => $fake_handle,
        pid                => $child_pid,
        started_at         => time,
        assigned_resources => [],
    };
    push @{$h->scheduler->queue} => $run;

    $h->perform_hard_stop;

    # Give the OS a moment to finish reaping.
    sleep(0.1);

    ok(!kill(0, $child_pid),        'child is dead');
    ok(!keys %{$h->job_tracker->running_jobs}, 'running_jobs cleared');
};

subtest 'run_should_end honors state and workers' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    ok(!$h->run_should_end, 'running + empty queue: keep running');

    $h->{state} = 'finishing';
    ok($h->run_should_end, 'finishing + empty queue + no running jobs: end');

    $h->job_tracker->running_jobs->{'j1'} = {pid => 123};
    ok(!$h->run_should_end, 'finishing + running job: keep running');

    delete $h->job_tracker->running_jobs->{'j1'};
    $h->{state} = 'terminating';
    ok($h->run_should_end, 'terminating + no running jobs: end');
};

subtest 'run_on_general_message - job_complete_notify is a no-op' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    # A message object with content => { kind => 'job_complete_notify', ... }.
    my $fake_msg = bless {}, 'FakeMsg';
    no warnings 'once';
    *FakeMsg::content = sub { {
        kind    => 'job_complete_notify',
        run_id  => 'r1',
        job_id  => 'j1',
        job_try => 1,
    } };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $ok = eval { $h->run_on_general_message($fake_msg); 1 };
    ok($ok, 'job_complete_notify message does not die');
    is(\@warnings, [], 'no warnings for known kind');
};

subtest 'run_on_general_message - resource state messages flip the named resource' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # JobCount cannot be broken, so use a breakable fixture resource
    # for this test; Test::Restart::Res has full state plumbing.
    my $res = Test::Restart::Res->new(pids => []);

    # The harness also needs a job limiter to boot, so add one that
    # is a plain JobCount. run_on_general_message looks up by name,
    # so the fixture must have a distinct resource_name from 'jobcount'
    # to avoid ambiguity. (Test::Restart::Res default name is 'res'.)
    my $h     = Test2::Harness2->new(workdir => $dir, resources => [$res]);
    my $rname = $res->resource_name;

    my $make_msg = sub {
        my ($k) = @_;
        my $pkg = 'FakeMsg::' . $k;
        my $obj = bless {}, $pkg;
        no strict 'refs';
        no warnings 'once', 'redefine';
        *{"${pkg}::content"} = sub { {kind => $k, resource => $rname} };
        return $obj;
    };

    $h->run_on_general_message($make_msg->('resource_paused'));
    ok($res->is_paused,  'resource marked paused');
    ok(!$res->is_usable, 'paused resource is not usable');

    $h->run_on_general_message($make_msg->('resource_resumed'));
    ok(!$res->is_paused, 'resumed clears pause');

    $h->run_on_general_message($make_msg->('resource_broken'));
    ok($res->is_broken, 'marked broken');

    $h->run_on_general_message($make_msg->('resource_ready'));
    ok(!$res->is_broken, 'ready clears broken');

    $h->run_on_general_message($make_msg->('resource_permanent_broken'));
    ok($res->is_permanent_broken, 'permanently broken');
    ok($res->is_broken,           'also broken');

    # Sticky: resumed must not un-permanent.
    $h->run_on_general_message($make_msg->('resource_resumed'));
    ok($res->is_permanent_broken, 'permanent brokenness survives resume');
};

subtest 'run_on_general_message - unknown resource name is a no-op' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $fake_msg = bless {}, 'FakeMsgUnknownRes';
    no warnings 'once';
    *FakeMsgUnknownRes::content = sub { {kind => 'resource_broken', resource => 'not-a-real-name'} };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    ok(lives { $h->run_on_general_message($fake_msg) }, 'tolerates unknown resource name');
    is(\@warnings, [], 'no warning for a known kind with a stale resource');
};

sub _track_one {
    my ($h, $res, %extra) = @_;
    $h->track_resource_service(
        resource      => $res,
        service_class => $res->service_class,
        service_args  => [],
        name          => 'foo',
        %extra,
    );
}

subtest 'run_on_pid: restartable exit flips to broken and re-invokes' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $res = Test::Restart::Res->new(pids => [71011], restartable_flag => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    _track_one($h, $res, pid => 71001);
    $h->run_on_pid(71001, 0);

    ok($res->is_broken,                        'restartable service exit marks resource broken');
    ok(!$res->is_permanent_broken,             'not permanently broken');
    ok(!exists $h->{resource_services}{71001}, 'old pid removed after restart');
    ok(exists $h->{resource_services}{71011},  'restartable service re-invoked');
};

subtest 'run_on_pid: non-restartable exit flips straight to permanent_broken' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $res = Test::Restart::Res->new(pids => [71003], restartable_flag => 0);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    _track_one($h, $res, pid => 71002);
    $h->run_on_pid(71002, 0);

    ok($res->is_permanent_broken,              'non-restartable service exit marks permanently broken');
    ok($res->is_broken,                        'also broken (per role contract)');
    ok(!exists $h->{resource_services}{71002}, 'pid removed after exit');
};

subtest 'restart: successful re-invocation tracks a new pid with attempts+1' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Only one restart iteration: spawn will be called once and
    # return pid 88002. The original pid (88001) was seeded directly.
    my $res = Test::Restart::Res->new(pids => [88002]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    _track_one(
        $h, $res,
        pid        => 88001,
        started_at => time,
        attempts   => 1,
    );

    $h->run_on_pid(88001, 0);

    ok(!exists $h->{resource_services}{88001}, 'old pid removed');
    ok(exists $h->{resource_services}{88002},  'new pid tracked after restart');
    is($h->{resource_services}{88002}{attempts}, 2, 'attempts counter incremented');
    ok($res->is_broken,            'resource stays broken until service signals ready');
    ok(!$res->is_permanent_broken, 'not permanently broken');
};

subtest 'restart: attempts cap flips to permanent_broken' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::Restart::Res->new(pids => [88101]);                     # only one pid: would be consumed if spawn ran
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    _track_one(
        $h, $res,
        pid        => 88100,
        started_at => time,
        attempts   => $h->max_restart_attempts,
    );

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        $h->run_on_pid(88100, 0);
    }

    ok($res->is_permanent_broken, 'resource permanently broken once attempts exhausted');
    ok(
        (grep { /exceeded.*restart attempts/ } @warnings),
        'warning mentions the attempts cap',
    );
    # Reinforce that the cap short-circuits BEFORE re-spawn: no pid
    # was consumed from the queue and nothing new is tracked.
    is(scalar @{$res->pids}, 1, 'spawn was not invoked when attempts cap hit');
    ok(!(keys %{$h->{resource_services}}), 'no tracked entries after cap');
};

subtest 'restart: spawn dying during re-invocation flips to permanent_broken' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Restartable resource whose next spawn throws: per the new
    # contract an exception during start is treated as
    # permanent_broken.
    my $res = Test::Restart::Res->new(pids => [88401], die_on_start => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    my @emits;
    {
        no warnings 'redefine';
        local *Test2::Harness2::emit_service_event = sub { push @emits => {@_[1 .. $#_]} };

        _track_one(
            $h, $res,
            pid        => 88400,
            started_at => time,
            attempts   => 1,
        );
        $h->run_on_pid(88400, 0);
    }

    ok($res->is_permanent_broken, 'exception during restart flips to permanent_broken');
    ok(
        (grep { ($_->{kind} // '') eq 'resource_service_start_failed' } @emits),
        'host emits resource_service_start_failed',
    );
};

subtest 'restart: healthy runtime resets the attempts counter' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::Restart::Res->new(pids => [88201]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    _track_one(
        $h, $res,
        pid        => 88200,
        started_at => time - ($h->restart_healthy_secs + 1),
        attempts   => $h->max_restart_attempts,
    );

    $h->run_on_pid(88200, 0);

    ok(exists $h->{resource_services}{88201}, 'new pid tracked after healthy-runtime reset');
    is($h->{resource_services}{88201}{attempts}, 1, 'attempts counter reset to 1');
    ok(!$res->is_permanent_broken, 'not permanently broken');
};

subtest 'no run service is spawned (Stage 9 of the flatten); harness writes the run spec directly' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $run = Test2::Harness2::Run->from_files(run_id => 1, files => _tfs('x.t'));
    my $h   = Test2::Harness2->new(workdir => $dir);
    push @{$h->scheduler->queue} => $run;
    $h->scheduler->queue_run($run);

    $h->{ipcm_info} = {fake => 1};

    {
        no warnings 'redefine';
        local *Test2::Harness2::_spawn_collector_for_job = sub {
            return {ok => 1, pid => 22_222};
        };

        $h->run_on_all({});
        $h->run_on_all({});
    }

    ok(!keys %{$h->{run_services} // {}}, 'no RUN_SERVICES entry tracked');
    ok(-e "$dir/logs/runs/" . $run->run_id . "/spec.jsonl",
        'harness wrote runs/<id>/spec.jsonl directly');
};

subtest 'per-run resources participate in _evaluate_resources_for' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $global_limiter = Test2::Harness2::Resource::JobCount->new(slots => 4);
    my $run_limiter    = Test2::Harness2::Resource::JobCount->new(slots => 4);
    $run_limiter->mark_paused;    # per-run resource defers

    my $h = Test2::Harness2->new(workdir => $dir, resources => [$global_limiter]);

    my $run = Test2::Harness2::Run->from_files(
        run_id    => 0,
        files     => _tfs('x.t'),
        resources => [$run_limiter],
    );
    push @{$h->scheduler->queue} => $run;

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub { die "must not launch when run-resource defers" };
        $h->run_on_all({});
    }

    is($global_limiter->used,             0, 'global limiter not consumed when run-resource defers');
    is($run_limiter->used,                0, 'run limiter not consumed either');
    is(scalar keys %{$h->job_tracker->running_jobs}, 0, 'no running jobs');
};

subtest 'run_on_cleanup tears down per-run resource pids via kill_run' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->from_files(run_id => 1, files => _tfs('never-runs.t'));

    my $h = Test2::Harness2->new(workdir => $dir);
    push @{$h->scheduler->queue} => $run;

    # Fork a short-lived child as a pretend per-run resource service
    # pid. run_on_cleanup -> _teardown_run_service ->
    # pid_index->kill_run should TERM it.
    my $child_pid = fork // die "fork: $!";
    if (!$child_pid) {
        my $done = 0;
        $SIG{TERM} = sub { $done = 1 };
        my $deadline = time + 30;
        until ($done) {
            last if time > $deadline;
            CORE::sleep 1;
        }
        POSIX::_exit($done ? 0 : 255);
    }

    $run->{resources_started} = 1;
    $h->pid_index->register(
        $run->run_id, $child_pid,
        kind     => 'resource_service',
        res_name => 'fake',
        res_svc  => 'fake',
        scope    => 'run',
    );

    {
        no warnings 'redefine';
        local *Test2::Harness2::perform_hard_stop  = sub { $_[0]->scheduler->clear_queue; $_[0]->job_tracker->clear_running_jobs };
        local *Test2::Harness2::emit_service_event = sub { };
        $h->run_on_cleanup;
    }

    my $deadline = time + 15;
    my $reaped;
    until ($reaped) {
        $reaped = waitpid($child_pid, POSIX::WNOHANG()) > 0;
        last if $reaped;
        last if time > $deadline;
        sleep(0.05);
    }
    kill 'KILL', $child_pid unless $reaped;
    waitpid($child_pid, 0) unless $reaped;

    ok($reaped, 'per-run pid exited after run_on_cleanup TERM cascade');
};

# Mocks Collector spawning for the broken-resource subtests: captures
# every _spawn_collector_for_job call so tests can assert the
# unavailable-action perl -e command. The recorded shape mirrors the
# old launch_job payload (peer/payload) so the existing assertions
# keep working with minimal churn.
sub _mock_run_launches {
    my ($h, $code) = @_;

    my @calls;
    no warnings 'redefine';
    local *Test2::Harness2::RunService::spawn = sub { 90_000 };
    local *Test2::Harness2::_spawn_collector_for_job = sub {
        my ($self, $run, $job, %opts) = @_;
        push @calls => {
            peer    => "run-" . $run->run_id,
            payload => {
                request   => 'launch_job',
                run_id    => $run->run_id,
                job_id    => $job->job_id,
                job_try   => $job->job_try,
                test_file => $job->test_file_abs,
                env       => {%{$opts{env} // {}}},
                (defined $opts{launch} ? (launch => $opts{launch}) : ()),
            },
        };
        return {ok => 1, pid => 70_000 + scalar @calls};
    };

    $h->{ipcm_info} //= {fake => 1};
    $code->();

    return \@calls;
}

subtest 'broken_resource_behavior=skip launches a real perl -e skip_all (default)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a   = Test2::Harness2::Resource::JobCount->new(slots => 1);
    my $b   = Test::Restart::Res->new(pids => []);
    $b->mark_permanent_broken;

    my $h = Test2::Harness2->new(workdir => $dir, resources => [$a, $b]);
    is($h->broken_resource_behavior, 'skip', 'default is skip');

    $h->request_handler_queue_test_run({files => _tfs('/abs/skipped.t')});
    my $calls = _mock_run_launches($h, sub { $h->run_on_all({}) });

    is(scalar @$calls, 1, 'one unavailable-action launch_job issued');
    my $cmd = $calls->[0]{payload}{launch};
    is(ref($cmd), 'ARRAY', 'launch is an arrayref');
    is($cmd->[0], $^X,     'command uses this perl');
    is($cmd->[1], '-Ilib', '-Ilib so harness plumbing resolves the same as a real test');
    is($cmd->[2], '-e',    '-e mode');
    like($cmd->[3], qr/skip_all/,      'one-liner calls skip_all');
    like($cmd->[3], qr/use Test2::V0/, 'one-liner uses Test2::V0');
    is($cmd->[4], '--', 'ARGV separator');
    like(
        $cmd->[5], qr/Missing resources: \Q${\ $b->resource_name }\E/,
        'reason names the broken resource'
    );
    is($a->used, 1, 'the job limiter took a slot for the unavailable-action launch');
};

subtest 'broken_resource_behavior=fail launches perl -e die' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a   = Test2::Harness2::Resource::JobCount->new(slots => 1);
    my $b   = Test::Restart::Res->new(pids => []);
    $b->mark_permanent_broken;

    my $h = Test2::Harness2->new(
        workdir                  => $dir,
        resources                => [$a, $b],
        broken_resource_behavior => 'fail',
    );

    $h->request_handler_queue_test_run({files => _tfs('/abs/failed.t')});
    my $calls = _mock_run_launches($h, sub { $h->run_on_all({}) });

    is(scalar @$calls, 1, 'one unavailable-action launch_job issued');
    my $cmd = $calls->[0]{payload}{launch};
    is($cmd->[2], '-e', '-e mode');
    like($cmd->[3], qr/\Adie /, 'one-liner dies');
    like(
        $cmd->[5], qr/Missing resources: \Q${\ $b->resource_name }\E/,
        'reason names the broken resource'
    );
};

subtest 'broken_resource_behavior=abort fails every remaining job in the run' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a   = Test2::Harness2::Resource::JobCount->new(slots => 1);
    my $b   = Test::Restart::Res->new(pids => []);
    $b->mark_permanent_broken;

    my $h = Test2::Harness2->new(
        workdir                  => $dir,
        resources                => [$a, $b],
        broken_resource_behavior => 'abort',
    );

    $h->request_handler_queue_test_run({files => _tfs('/abs/a.t', '/abs/b.t', '/abs/c.t')});

    my $calls = _mock_run_launches(
        $h,
        sub {
            # One launch per scheduler tick; the single-slot limiter
            # only lets one unavailable-action fail run at a time, so
            # drain them by feeding the harness the IPC pair the
            # auditor now sends directly (test_job_completed +
            # job_release).
            while (keys %{$h->job_tracker->running_jobs} || @{$h->scheduler->queue}) {
                $h->run_on_all({});
                last unless keys %{$h->job_tracker->running_jobs};

                for my $jid (keys %{$h->job_tracker->running_jobs}) {
                    my $entry = $h->job_tracker->running_jobs->{$jid};
                    my $run   = $entry->{run};

                    $h->run_on_general_message(Test::FakeIpcMsg->new({
                        kind       => 'test_job_completed',
                        run_id     => $run->run_id,
                        job_id     => $entry->{job}->job_id,
                        pass       => 0,
                        pass_count => 0,
                        fail_count => 1,
                        stamp      => time,
                    }));
                    $h->run_on_general_message(Test::FakeIpcMsg->new({
                        kind   => 'job_release',
                        run_id => $run->run_id,
                        job_id => $entry->{job}->job_id,
                    }));
                }
            }
        }
    );

    is(scalar @$calls, 3, 'three unavailable-action launches -- one per job');
    my @cmds = map { $_->{payload}{launch} } @$calls;
    ok(!(grep { $_->[3] =~ /skip_all/ } @cmds), 'no job took the skip path under abort');
    ok(
        (grep { $_->[5] =~ /\ARun aborted: / } @cmds),
        'follow-up jobs carry the "Run aborted" reason prefix'
    );
    is(scalar @{$h->scheduler->queue}, 0, 'run closed out after abort');
};

subtest 'invalid broken_resource_behavior is rejected at construction' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ok  = eval { Test2::Harness2->new(workdir => $dir, broken_resource_behavior => 'bogus'); 1 };
    my $err = $@;
    ok(!$ok, 'construction croaks');
    like($err, qr/invalid broken_resource_behavior 'bogus'/);
};

subtest 'run_on_general_message - unknown kind warns' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $fake_msg = bless {}, 'FakeMsgUnknown';
    no warnings 'once';
    *FakeMsgUnknown::content = sub { {kind => 'some_future_thing'} };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $ok = eval { $h->run_on_general_message($fake_msg); 1 };
    ok($ok, 'unknown kind does not die');
    is(scalar @warnings, 1, 'one warning for unknown kind');
    like($warnings[0], qr/unhandled general message/, 'warning is descriptive');
};

subtest 'start - jump_to unwinds the interpose child via Long::Jump' => sub {
    skip_all "fork required" unless $CAN_FORK;
    require Long::Jump;

    my $dir = tempdir(CLEANUP => 1);

    my $outer = fork() // die "fork: $!";
    if (!$outer) {
        # Exit codes communicate results back to the test process:
        #   0 -- setjump caught the longjump and got a CODE-ref payload
        #   3 -- setjump returned but payload was not a CODE ref
        # 100 -- start() returned to this code path instead of longjumping
        # Anything else -- unexpected
        my $ret = Long::Jump::setjump(
            'harness_pt',
            sub {
                Test2::Harness2->start(
                    workdir     => $dir,
                    ipcm_info   => {fake => 1},
                    jump_to     => 'harness_pt',
                    parent_pids => [],
                    loggers     => classic_harness_loggers($dir),
                );
                POSIX::_exit(100);
            }
        );

        my $payload = ($ret && @$ret) ? $ret->[0] : undef;
        POSIX::_exit(3) unless ref($payload) eq 'CODE';
        POSIX::_exit(0);
    }

    waitpid($outer, 0);
    is($? >> 8, 0, 'interpose child reached the setjump with a CODE-ref payload');
    ok(-e "$dir/logs/services/harness/events.jsonl.zst", 'service events file was created by the collector');
};

subtest 'run_on_start sets up pgid (smoke test)' => sub {
    # We can't safely setpgid in the test process itself, so mock POSIX::setpgid.
    my $called;
    {
        no warnings 'redefine';
        local *POSIX::setpgid = sub { $called = [@_]; 1 };
        my $dir = tempdir(CLEANUP => 1);
        my $h   = Test2::Harness2->new(workdir => $dir);
        $h->run_on_start;
    }
    is($called, [0, 0], 'setpgid(0,0) was called');
};

subtest 'run_on_start calls ChildSubReaper when available' => sub {
    skip_all "ChildSubReaper support is not present in this build"
        unless Test2::Harness2::HAS_CHILD_SUBREAPER();

    my @calls;
    no warnings 'redefine';
    local *POSIX::setpgid                                       = sub { 1 };
    local *Test2::Harness2::ChildSubReaper::set_child_subreaper = sub {
        push @calls => [@_];
        return 1;
    };

    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->run_on_start;

    is(scalar @calls, 1,   'set_child_subreaper called once');
    is($calls[0],     [1], 'called with (1) to enable the flag');
};

subtest 'HAS_CHILD_SUBREAPER compiles to 0 when the module is absent' => sub {
    # The HAS_CHILD_SUBREAPER constant is resolved at compile time, so we
    # have to load Test2::Harness2 in a fresh perl interpreter to
    # exercise the "module not installed" path. The @INC hook rejects
    # any attempt to load Test2::Harness2::ChildSubReaper before the
    # constant is evaluated.
    my $script = <<'END_PERL';
unshift @INC, sub {
    my (undef, $filename) = @_;
    die "hidden by test\n"
        if $filename eq 'Test2/Harness2/ChildSubReaper.pm';
    return undef;
};
require Test2::Harness2;
exit(Test2::Harness2::HAS_CHILD_SUBREAPER() ? 1 : 0);
END_PERL

    my @cmd = ($^X, (map { "-I$_" } grep { -d $_ } @INC), '-e', $script);
    system(@cmd);
    is($? >> 8, 0, 'constant is false when the module cannot be loaded');
};

subtest 'run_on_start warns when set_child_subreaper fails' => sub {
    skip_all "ChildSubReaper support is not present in this build"
        unless Test2::Harness2::HAS_CHILD_SUBREAPER();

    no warnings 'redefine';
    local *POSIX::setpgid                                       = sub { 1 };
    local *Test2::Harness2::ChildSubReaper::set_child_subreaper = sub { $! = 1; 0 };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->run_on_start;

    ok(
        (grep { /set_child_subreaper failed/ } @warnings),
        'failure is surfaced via warn'
    );
};

subtest 'collector pid exit without test_job_completed is grace-armed and synthesized by the watchdog' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(
        workdir              => $dir,
        resources            => [Test2::Harness2::Resource::JobCount->new(slots => 1)],
        collector_grace_secs => 0,
    );

    my $run    = Test2::Harness2::Run->from_files(run_id => 1, files => _tfs('/abs/orphan.t'));
    my $job_id = $run->jobs->[0]->job_id;
    push @{$h->scheduler->queue} => $run;
    my $rstate = Test2::Harness2::Run::State->new(
        run_id  => $run->run_id,
        pending => [$job_id],
    );
    $h->{run_states}->set_state($run->run_id, $rstate);
    $rstate->mark_running($job_id);

    my ($res) = @{$h->{resources}};
    $res->assign(id => 'orphan-assign', job => $run->jobs->[0], env => {});

    $h->job_tracker->running_jobs->{$job_id} = {
        run                => $run,
        job                => $run->jobs->[0],
        pid                => 77777,
        started_at         => time,
        assign_id          => 'orphan-assign',
        assigned_resources => [$res],
    };

    # Pid exit before any test_job_completed: arms a synth entry,
    # leaves running_jobs alone for the watchdog to claim.
    $h->run_on_pid(77777, 0);
    ok(exists $h->job_tracker->running_jobs->{$job_id}, 'running_jobs not yet cleared (watchdog owns it)');
    is($res->used, 1, 'resource slot still committed during grace window');
    ok(
        exists $h->job_tracker->pending_synth_completions->{$job_id},
        'pending synth-completion entry armed',
    );

    # Watchdog tick with grace=0 elapsed: synthesize test_job_completed
    # and run the orphan release path.
    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        $h->run_on_interval;
    }

    ok(!exists $h->job_tracker->running_jobs->{$job_id}, 'running_jobs cleared by watchdog');
    is($res->used, 0, 'resource slot released');
    ok(
        !exists $h->job_tracker->pending_synth_completions->{$job_id},
        'pending synth-completion entry cleared',
    );
    ok(
        (grep { /synthesizing test_job_completed/ } @warnings),
        'warned about synth path',
    );

    my $result = $rstate->results->{$job_id};
    ok($result, 'result entry recorded for orphan job');
    is($result->{pass}, 0, 'orphan job marked failed');
    is($result->{exit}, 0, 'orphan job exit captured (raw)');
};

subtest 'perform_hard_stop TERMs reparented descendants on Linux' => sub {
    skip_all "fork required"        unless $Config{d_fork};
    skip_all "Linux /proc required" unless -d '/proc';
    skip_all "ChildSubReaper support is not present in this build"
        unless Test2::Harness2::HAS_CHILD_SUBREAPER();

    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir, kill_timeout => 3);

    # Fork a long-running child that catches TERM so we can verify hard_stop
    # actually sent the signal rather than the kernel killing the child for
    # some other reason.
    my $kid = fork // die "fork: $!";
    if (!$kid) {
        $SIG{TERM} = sub { POSIX::_exit(0) };
        sleep 30;
        POSIX::_exit(99);
    }

    # Not in CURRENT, not in workers -- the only path that picks it up is
    # the subreaper-descendant enumeration inside perform_hard_stop.
    $h->perform_hard_stop;

    # Hard stop waitpid's everything, so the child is gone.
    ok(!kill(0, $kid), 'reparented descendant was terminated and reaped');
};

subtest 'perform_hard_stop catches grandchildren reparented mid-kill' => sub {
    skip_all "fork required"        unless $Config{d_fork};
    skip_all "Linux /proc required" unless -d '/proc';
    skip_all "ChildSubReaper support is not present in this build"
        unless Test2::Harness2::HAS_CHILD_SUBREAPER();

    my $dir = tempdir(CLEANUP => 1);

    # Short grace so A's TERM->KILL escalation happens quickly, then
    # X gets the same treatment from a fresh window.
    my $h = Test2::Harness2->new(workdir => $dir, kill_timeout => 1);

    # Build a two-level tree: A is our direct child, X is A's child.
    # A IGNOREs TERM so it can only die from KILL; that forces X's
    # reparenting to happen during the KILL phase of the outer loop.
    # X must still get its own TERM first with a fresh grace window,
    # not inherit A's KILL.
    my $x_flag = "$dir/x_got_term";
    pipe(my $pipe_r, my $pipe_w) or die "pipe: $!";
    my $a = fork // die "fork: $!";
    if (!$a) {
        close $pipe_r;

        my $x = fork // die "fork: $!";
        if (!$x) {
            close $pipe_w;
            $SIG{TERM} = sub {
                open(my $fh, '>', $x_flag) or POSIX::_exit(2);
                print $fh "got TERM\n";
                close $fh;
                POSIX::_exit(0);
            };
            sleep 30;
            POSIX::_exit(99);
        }

        # A: report X's pid, ignore TERM, wait for KILL. X must outlive
        # A long enough to reparent to the test process.
        syswrite($pipe_w, "$x\n");
        close $pipe_w;
        $SIG{TERM} = 'IGNORE';
        sleep 30;
        POSIX::_exit(99);
    }
    close $pipe_w;

    my $x_line = <$pipe_r>;
    chomp $x_line;
    my $x = $x_line + 0;
    close $pipe_r;

    ok(kill(0, $a), 'A is alive pre-stop');
    ok(kill(0, $x), 'X is alive pre-stop');

    $h->perform_hard_stop;

    ok(!kill(0, $a), 'A reaped');
    ok(!kill(0, $x), 'X (reparented grandchild) also reaped');
    ok(
        -f $x_flag,
        'X received its own TERM grace window (not just KILL after A fell)'
    );
};

done_testing;
