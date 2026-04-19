use Test2::V0;
use Config;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use POSIX qw/WNOHANG/;
use Time::HiRes qw/sleep/;

use lib 't/lib';
use Test2::Harness2::TestFile;

use Test2::Harness2;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Run;

my $CAN_FORK = $Config{d_fork};

# Inline test resources for the restart and per-run subtests.
# Test::Restart::Res drives restart cases: SERVICE_RETURNS is a queue of
# codes the method returns on each call; PIDS is a queue of pids to track
# on each successful (>= 0) call.
{

    package Test::Restart::Res;
    use Object::HashBase qw/<service_returns <pids/;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Resource';
    sub available { 1 }
    sub assign    { 1 }
    sub release   { 1 }
    sub status    { {} }

    sub service_foo {
        my ($self, %p) = @_;
        my $ret = shift @{$self->{+SERVICE_RETURNS}};
        return $ret if !defined($ret) || $ret < 0;
        my $pid = shift @{$self->{+PIDS}};
        $p{harness}->track_resource_service(
            pid      => $pid,
            resource => $self,
            method   => 'service_foo',
            scope    => $p{scope},
            ($p{run} ? (run => $p{run}) : ()),
        );
        return $ret;
    }
}

# Per-run resource-service lifecycle (invocation of service_* methods,
# teardown calls) lives in the run-service process after the harness
# refactor; those tests live in t/unit/Harness2/RunService.t. Here we
# only exercise the harness's scheduling-side handling of per-run
# resources and the lazy spawn of the run service itself.

subtest 'constructs with valid workdir' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    is($h->workdir, $dir,      'workdir stored');
    is($h->name,    'harness', 'name defaults to "harness"');
    like($h->job_id, qr/^[0-9A-F-]{36}$/i, 'job_id auto-generated');
    ok(-d "$dir/services", 'services/ dir created');
};

subtest 'rejects existing services/ directory' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/services");
    my $ok  = eval { Test2::Harness2->new(workdir => $dir); 1 };
    my $err = $@;
    ok(!$ok, 'constructor dies');
    like($err, qr/services/, 'error mentions services');
};

subtest 'rejects existing runs/ directory' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path("$dir/runs");
    my $ok = eval { Test2::Harness2->new(workdir => $dir); 1 };
    ok(!$ok, 'constructor dies on pre-existing runs/');
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
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $status = $h->request_handler_status;

    is($status->{service}{name},    'harness');
    is($status->{service}{pid},     $$);
    is($status->{service}{workdir}, $dir);
    is($status->{service}{state},   'running');
    like($status->{service}{job_id}, qr/^[0-9A-F-]{36}$/i);
    is($status->{queue},                  [],         'empty queue');
    is($status->{running},                [],         'nothing running');
    is(scalar @{$status->{resources}},    1,          'default JobCount resource installed');
    is($status->{resources}[0]{resource}, 'jobcount', 'resource name surfaces');
};

subtest 'queue_test_run enqueues and returns run_id' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_queue_test_run({files => ['t/a.t', 't/b.t']});
    ok($res->{ok}, 'accepted');
    like($res->{run_id}, qr/^[0-9A-F-]{36}$/i, 'returns a run_id');

    my $status = $h->request_handler_status;
    is(scalar @{$status->{queue}},             1,              'one run queued');
    is($status->{queue}[0]{run_id},            $res->{run_id}, 'matches returned id');
    is(scalar @{$status->{queue}[0]{pending}}, 2,              'two pending jobs');
};

subtest 'queue_test_run uses provided run_id when given' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    my $res = $h->request_handler_queue_test_run({files => ['t/x.t'], run_id => 'my-id'});
    is($res->{run_id}, 'my-id');
};

subtest 'queue_test_run rejects when state is not running' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->{state} = 'finishing';
    my $res = $h->request_handler_queue_test_run({files => ['t/x.t']});
    ok(!$res->{ok}, 'rejected');
    like($res->{error}, qr/not accepting/);
};

subtest 'finish transitions running -> finishing and rejects further queueing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $res = $h->request_handler_finish;
    ok($res->{ok}, 'finish accepted');
    is($h->{state}, 'finishing', 'state transitioned');

    my $q = $h->request_handler_queue_test_run({files => ['t/x.t']});
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

subtest 'run_on_all dispatches next pending job to a Collector' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    # Use a self-contained script as the "test" so we don't need a real .t file.
    $h->request_handler_queue_test_run({files => ['does-not-matter.t']});

    # Record only the first spawn; after that return a sentinel and stop
    # consuming slots so the launcher loop exits cleanly.
    my @collector_args;
    my $fake_handle = bless {pid => 99999}, 'Test2::Harness2::Collector::Handle';
    my $calls       = 0;
    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub {
            my ($class, %args) = @_;
            if (!$calls++) {
                @collector_args = %args;
                return $fake_handle;
            }
            die "only one spawn expected under a single-slot JobCount";
        };

        $h->run_on_all({});
    }

    ok(@collector_args, 'spawn was called');
    my %args = @collector_args;
    is($args{new_pgroup},             1,         'new_pgroup set');
    is($args{parent_pids},            [$$],      'parent_pids includes service pid');
    is($args{env_vars}{T2_FORMATTER}, 'Stream2', 'T2_FORMATTER set');
    is(
        $args{env_vars}{T2_HARNESS_MY_JOB_CONCURRENCY}, 1,
        'JobCount injected concurrency env var'
    );
    like($args{loggers}[0][2], qr{\Q$dir\E/runs/.+/.+/0\.jsonl}, 'per-job JSONL path');
    like($args{run_id},        qr/^[0-9A-F-]{36}$/i,             'run_id passed to collector');
    like($args{job_id},        qr/^[0-9A-F-]{36}$/i,             'job_id passed to collector');
    is($args{job_try}, 0, 'job_try passed as 0 to collector');
    ok(!exists $args{env_vars}{T2_IPC_INFO}, 'ipcm_info not in env_vars (not passed to test process)');
    my @running = values %{$h->{running_jobs}};
    is(scalar @running,    1,     'one running job tracked');
    is($running[0]->{pid}, 99999, 'running job pid set from handle');

    my $status = $h->request_handler_status;
    is(scalar @{$status->{running}}, 1, 'status reports one running job');
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

    $h->request_handler_queue_test_run({files => ['x.t']});

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub {
            die "must not spawn when a resource defers";
        };
        $h->run_on_all({});
    }

    is($res_a->used,                      0, 'resource A not committed when B defers');
    is($res_b->used,                      0, 'resource B not committed');
    is(scalar keys %{$h->{running_jobs}}, 0, 'no running jobs');
    is(scalar @{$h->{queue}},             1, 'run still queued, job still pending');
};

subtest 'run_on_all detects collector exit and advances queue' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    $h->request_handler_queue_test_run({files => ['dummy.t']});

    my $run    = $h->{queue}[0];
    my $job_id = $run->pending->[0];
    my ($job)  = grep { $_->job_id eq $job_id } @{$run->jobs};
    $run->mark_running($job_id);

    # Fork a child that exits immediately so we have a reapable pid.
    my $child_pid = fork // die "fork: $!";
    if (!$child_pid) { POSIX::_exit(0); }

    my $fake_handle = bless {pid => $child_pid}, 'Test2::Harness2::Collector::Handle';

    # Give the child a moment to exit before we check.
    sleep(0.1);

    # Pre-assign the JobCount slot so _check_completions can release it.
    my ($res) = @{$h->{resources}};
    my %env;
    $res->assign(id => 'test-assign', job => $job, env => \%env);

    $h->{running_jobs}{$job_id} = {
        run                => $run,
        job                => $job,
        handle             => $fake_handle,
        pid                => $child_pid,
        started_at         => time,
        assign_id          => 'test-assign',
        assigned_resources => [$res],
    };

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub { die "should not relaunch" };
        $h->run_on_all({});
    }

    ok(!keys %{$h->{running_jobs}}, 'running_jobs cleared after completion');
    is(scalar @{$run->done}, 1, 'job marked done');
    is($res->used,           0, 'JobCount slot released');
};

subtest '_perform_hard_stop TERMs tracked pids and reaps them' => sub {
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

    my $run    = Test2::Harness2::Run->from_files(files => ['dummy.t']);
    my $job_id = $run->pending->[0];
    my ($job)  = grep { $_->job_id eq $job_id } @{$run->jobs};
    $run->mark_running($job_id);

    $h->{running_jobs}{$job_id} = {
        run                => $run,
        job                => $job,
        handle             => $fake_handle,
        pid                => $child_pid,
        started_at         => time,
        assigned_resources => [],
    };
    push @{$h->{queue}} => $run;

    $h->_perform_hard_stop;

    # Give the OS a moment to finish reaping.
    sleep(0.1);

    ok(!kill(0, $child_pid),        'child is dead');
    ok(!keys %{$h->{running_jobs}}, 'running_jobs cleared');
};

subtest 'run_should_end honors state and workers' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    ok(!$h->run_should_end, 'running + empty queue: keep running');

    $h->{state} = 'finishing';
    ok($h->run_should_end, 'finishing + empty queue + no running jobs: end');

    $h->{running_jobs}{'j1'} = {pid => 123};
    ok(!$h->run_should_end, 'finishing + running job: keep running');

    delete $h->{running_jobs}{'j1'};
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
        job_try => 0,
    } };

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $ok = eval { $h->run_on_general_message($fake_msg); 1 };
    ok($ok, 'job_complete_notify message does not die');
    is(\@warnings, [], 'no warnings for known kind');
};

subtest 'run_on_general_message - resource state messages flip the named resource' => sub {
    my $dir   = tempdir(CLEANUP => 1);
    my $res   = Test2::Harness2::Resource::JobCount->new(slots => 1);
    my $h     = Test2::Harness2->new(workdir => $dir, resources => [$res]);
    my $kind  = 'resource_paused';
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

subtest 'run_on_pid resource-service branch flips state based on restart flag' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $res1 = Test2::Harness2::Resource::JobCount->new(slots => 1);    # restartable
    my $res2 = Test2::Harness2::Resource::JobCount->new(slots => 1);    # permanent
    my $h    = Test2::Harness2->new(workdir => $dir, resources => [$res1, $res2]);

    # JobCount has no service_* methods, so the restart branch's
    # re-invocation will die on method-not-found. That's a documented
    # path: the resource stays broken (not permanent) and a warning is
    # emitted. Capture the warning rather than leaking it to stderr.
    $h->track_resource_service(pid => 71001, resource => $res1, method => 'service_one', restart => 1);
    $h->track_resource_service(pid => 71002, resource => $res2, method => 'service_two', restart => 0);

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        $h->run_on_pid(71001, 0);
        $h->run_on_pid(71002, 0);
    }

    ok($res1->is_broken,            'restart=1 service exit marks resource broken');
    ok(!$res1->is_permanent_broken, 'not permanently broken');

    ok($res2->is_permanent_broken, 'restart=0 service exit marks permanently broken');
    ok($res2->is_broken,           'also broken (as per role contract)');

    ok(!exists $h->{resource_services}{71001}, 'tracked pid removed after exit');
    ok(!exists $h->{resource_services}{71002}, 'tracked pid removed after exit');

    ok(
        (grep { /service 'service_one' died/ } @warnings),
        'restart attempt warned when the method could not be called',
    );
};

subtest 'restart: successful re-invocation tracks a new pid with attempts+1' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Only one restart iteration: the service method will be called once
    # and track pid 88002. The original pid (88001) was seeded directly
    # so the service method's pid queue doesn't need to produce it.
    my $res = Test::Restart::Res->new(service_returns => [1], pids => [88002]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->track_resource_service(
        pid        => 88001,
        resource   => $res,
        method     => 'service_foo',
        restart    => 1,
        started_at => time,
        attempts   => 1,
    );

    $h->run_on_pid(88001, 0);

    ok(!exists $h->{resource_services}{88001}, 'old pid removed');
    ok(exists $h->{resource_services}{88002},  'new pid tracked after restart');
    is($h->{resource_services}{88002}{attempts}, 2, 'attempts counter incremented');
    is($h->{resource_services}{88002}{restart},  1, 'restart flag preserved from new return value');
    ok($res->is_broken,            'resource stays broken until service signals ready');
    ok(!$res->is_permanent_broken, 'not permanently broken');
};

subtest 'restart: attempts cap flips to permanent_broken' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::Restart::Res->new(service_returns => [], pids => []);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->track_resource_service(
        pid        => 88100,
        resource   => $res,
        method     => 'service_foo',
        restart    => 1,
        started_at => time,
        attempts   => Test2::Harness2::MAX_RESTART_ATTEMPTS(),
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
    # Reinforce that the cap short-circuits BEFORE re-invocation: the
    # service_returns queue should still be empty, and no new pid should
    # have been tracked.
    is($res->service_returns, [], 'service method was not invoked when attempts cap hit');
    ok(!(keys %{$h->{resource_services}}), 'no tracked entries after cap');
};

subtest 'restart: method dying leaves the resource broken but not permanent' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Inline a resource whose service_foo dies explicitly. We want to
    # verify that the restart branch lands on the "method died" path,
    # which leaves the resource `broken` (so new assignments refuse) but
    # does NOT flip to permanent_broken -- operator intervention path.
    {

        package Test::DyingRes::Res;
        use Object::HashBase;
        use Role::Tiny::With;
        with 'Test2::Harness2::Role::Resource';
        sub available   { 1 }
        sub assign      { 1 }
        sub release     { 1 }
        sub status      { {} }
        sub service_foo { die "nope" }
    }

    my $res = Test::DyingRes::Res->new;
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->track_resource_service(
        pid        => 88400,
        resource   => $res,
        method     => 'service_foo',
        restart    => 1,
        started_at => time,
        attempts   => 1,
    );

    my @warnings;
    {
        local $SIG{__WARN__} = sub { push @warnings => @_ };
        $h->run_on_pid(88400, 0);
    }

    ok($res->is_broken,                                   'resource still broken after method-died restart');
    ok(!$res->is_permanent_broken,                        'method-died does NOT flip to permanent');
    ok((grep { /service 'service_foo' died/ } @warnings), 'method-died warning surfaces');
};

subtest 'restart: healthy runtime resets the attempts counter' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::Restart::Res->new(service_returns => [1], pids => [88201]);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->track_resource_service(
        pid        => 88200,
        resource   => $res,
        method     => 'service_foo',
        restart    => 1,
        started_at => time - (Test2::Harness2::RESTART_HEALTHY_SECS() + 1),
        attempts   => Test2::Harness2::MAX_RESTART_ATTEMPTS(),
    );

    $h->run_on_pid(88200, 0);

    ok(exists $h->{resource_services}{88201}, 'new pid tracked after healthy-runtime reset');
    is($h->{resource_services}{88201}{attempts}, 1, 'attempts counter reset to 1');
    ok(!$res->is_permanent_broken, 'not permanently broken');
};

subtest 'restart: method returning -1 marks permanent_broken' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $res = Test::Restart::Res->new(service_returns => [-1], pids => []);
    my $h   = Test2::Harness2->new(workdir => $dir, resources => [$res]);

    $h->track_resource_service(
        pid        => 88300,
        resource   => $res,
        method     => 'service_foo',
        restart    => 1,
        started_at => time,
        attempts   => 1,
    );

    $h->run_on_pid(88300, 0);

    ok($res->is_permanent_broken,          'service declined restart -> permanent_broken');
    ok(!(keys %{$h->{resource_services}}), 'no tracked entries remain');
};

subtest 'harness spawns a run service lazily for each run it considers' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $run = Test2::Harness2::Run->from_files(files => ['x.t']);
    my $h   = Test2::Harness2->new(workdir => $dir);
    push @{$h->{queue}} => $run;

    # Spoof ipcm_info so _ensure_run_service_started actually tries to
    # fork. Mock RunService->spawn so we don't really fork from the
    # test; capture what the harness handed it.
    $h->{ipcm_info} = {fake => 1};

    my @spawn_calls;
    my $fake_handle = bless {pid => 99991}, 'Test2::Harness2::Collector::Handle';
    {
        no warnings 'redefine';
        local *Test2::Harness2::RunService::spawn = sub {
            my ($class, %args) = @_;
            push @spawn_calls => \%args;
            return 91_001;    # pretend child pid
        };
        local *Test2::Harness2::Collector::spawn = sub { $fake_handle };

        $h->run_on_all({});
        $h->run_on_all({});    # a second tick must not re-fork
    }

    is(scalar @spawn_calls,      1,    'RunService->spawn called exactly once for the run');
    is($spawn_calls[0]{workdir}, $dir, 'workdir forwarded to run service');
    ref_is($spawn_calls[0]{run}, $run, 'Run object forwarded to run service');
    is(
        $h->{run_services}{$run->run_id}{pid},
        91_001,
        'harness tracked the run-service pid',
    );
};

subtest 'harness spawns a run service even when the run has no resources' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->from_files(files => ['y.t']);
    my $h   = Test2::Harness2->new(workdir => $dir);
    $h->{ipcm_info} = {fake => 1};
    push @{$h->{queue}} => $run;

    my @spawn_calls;
    my $fake_handle = bless {pid => 99992}, 'Test2::Harness2::Collector::Handle';
    {
        no warnings 'redefine';
        local *Test2::Harness2::RunService::spawn = sub {
            push @spawn_calls => {@_[1 .. $#_]};
            return 91_002;
        };
        local *Test2::Harness2::Collector::spawn = sub { $fake_handle };
        $h->run_on_all({});
    }

    is(scalar @spawn_calls, 1, 'run service spawned for a run with zero resources');
};

subtest 'run-service pid is recognized by run_on_pid and dropped cleanly' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    $h->{run_services}{r1} = {
        pid        => 91_050,
        run        => Test2::Harness2::Run->new(run_id => 'r1'),
        started_at => time,
    };

    # run_on_pid for this pid must drop the tracking entry but not
    # treat it as a resource-service exit (nothing to restart; the
    # RunService is responsible for cascading shutdown to its children).
    $h->run_on_pid(91_050, 0);

    ok(!exists $h->{run_services}{r1}, 'run-service pid cleared from tracking');
};

subtest 'per-run resources participate in _evaluate_resources_for' => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $global_limiter = Test2::Harness2::Resource::JobCount->new(slots => 4);
    my $run_limiter    = Test2::Harness2::Resource::JobCount->new(slots => 4);
    $run_limiter->mark_paused;    # per-run resource defers

    my $h = Test2::Harness2->new(workdir => $dir, resources => [$global_limiter]);

    my $run = Test2::Harness2::Run->from_files(
        files     => ['x.t'],
        resources => [$run_limiter],
    );
    push @{$h->{queue}} => $run;

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub { die "must not launch when run-resource defers" };
        $h->run_on_all({});
    }

    is($global_limiter->used,             0, 'global limiter not consumed when run-resource defers');
    is($run_limiter->used,                0, 'run limiter not consumed either');
    is(scalar keys %{$h->{running_jobs}}, 0, 'no running jobs');
};

subtest 'run_on_cleanup signals run services for uncompleted runs' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $run = Test2::Harness2::Run->from_files(files => ['never-runs.t']);

    my $h = Test2::Harness2->new(workdir => $dir);
    push @{$h->{queue}} => $run;

    # Fork a short-lived child as the pretend run-service pid. The
    # child just waits for a signal; run_on_cleanup should TERM it,
    # which we reap in the parent.
    my $child_pid = fork // die "fork: $!";
    if (!$child_pid) {
        $SIG{TERM} = sub { POSIX::_exit(0) };
        sleep 30;    # dies via SIGTERM from the harness, not the timer
        POSIX::_exit(255);
    }

    $run->{resources_started} = 1;
    $h->{run_services}{$run->run_id} = {
        pid        => $child_pid,
        run        => $run,
        started_at => time,
    };

    my @emits;
    {
        no warnings 'redefine';
        local *Test2::Harness2::_perform_hard_stop  = sub { $_[0]->{queue} = []; $_[0]->{running_jobs} = {} };
        local *Test2::Harness2::_emit_service_event = sub { push @emits => {@_[1 .. $#_]} };
        $h->run_on_cleanup;
    }

    # Wait for the child to exit (it should respond to the TERM we just sent).
    my $deadline = time + 5;
    my $reaped;
    until ($reaped) {
        $reaped = waitpid($child_pid, POSIX::WNOHANG()) > 0;
        last if $reaped;
        last if time > $deadline;
        sleep(0.05);
    }
    kill 'KILL', $child_pid unless $reaped;    # belt-and-braces cleanup
    waitpid($child_pid, 0) unless $reaped;

    ok($reaped,                                  'run-service pid exited after run_on_cleanup signalled it');
    ok(!exists $h->{run_services}{$run->run_id}, 'run-service tracking cleared');
};

subtest '_evaluate_resources_for returns skip when a resource is permanently broken' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $a   = Test2::Harness2::Resource::JobCount->new(slots => 4);
    my $b   = Test2::Harness2::Resource::JobCount->new(slots => 4);
    $b->mark_permanent_broken;

    my $h = Test2::Harness2->new(workdir => $dir, resources => [$a, $b]);

    $h->request_handler_queue_test_run({files => ['perm-broken.t']});

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub { die "permanently broken -> skip, not launch" };
        $h->run_on_all({});
    }

    is($a->used,                          0, 'no slot consumed on A');
    is(scalar keys %{$h->{running_jobs}}, 0, 'no running jobs');
    my $run_still_queued = scalar @{$h->{queue}};
    is($run_still_queued, 0, 'run removed after its only job was skipped');
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
    ok(-e "$dir/services/harness.jsonl", 'service log file was created by the collector');
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

subtest 'run_on_pid stashes exit status on the collector Handle' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $handle = bless {pid => 12345}, 'Test2::Harness2::Collector::Handle';
    $h->{running_jobs}{'j1'} = {pid => 12345, handle => $handle};

    $h->run_on_pid(12345, 256);
    is($handle->exit_code, 256, 'exit status forwarded to the owning Handle');

    # Subsequent reap of the same pid shouldn't clobber a pre-existing code.
    $h->run_on_pid(12345, 512);
    is($handle->exit_code, 256, 'existing exit_code is preserved');
};

subtest 'run_on_pid ignores pids that are not a tracked collector' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    my $handle = bless {pid => 12345}, 'Test2::Harness2::Collector::Handle';
    $h->{running_jobs}{'j1'} = {pid => 12345, handle => $handle};

    # Some other pid: a reparented descendant the service loop drained.
    # No-op -- no exception, Handle untouched.
    ok(lives { $h->run_on_pid(99999, 0) }, 'tolerates unknown pid');
    ok(!defined $handle->exit_code,        'Handle exit_code not touched');
};

subtest 'Handle::is_done short-circuits when exit_code is pre-set' => sub {
    my $handle = Test2::Harness2::Collector::Handle->new(pid => 99999999);
    $handle->set_exit_code(0);
    ok($handle->is_done, 'is_done returns true without calling waitpid');
};

subtest '_perform_hard_stop TERMs reparented descendants on Linux' => sub {
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
    # the subreaper-descendant enumeration inside _perform_hard_stop.
    $h->_perform_hard_stop;

    # Hard stop waitpid's everything, so the child is gone.
    ok(!kill(0, $kid), 'reparented descendant was terminated and reaped');
};

subtest '_perform_hard_stop catches grandchildren reparented mid-kill' => sub {
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

    $h->_perform_hard_stop;

    ok(!kill(0, $a), 'A reaped');
    ok(!kill(0, $x), 'X (reparented grandchild) also reaped');
    ok(
        -f $x_flag,
        'X received its own TERM grace window (not just KILL after A fell)'
    );
};

done_testing;
