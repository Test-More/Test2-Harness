use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use POSIX qw/WNOHANG/;

use Test2::Harness2;
use Test2::Harness2::Run;

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
    is($status->{queue},   [],    'empty queue');
    is($status->{running}, undef, 'nothing running');
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

    # Override the per-job launch so we're not spawning a real perl process.
    # Instead, record the args the Collector would be given.
    my @collector_args;
    my $fake_handle = bless {pid => 99999}, 'Test2::Harness2::Collector::Handle';
    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub {
            my ($class, %args) = @_;
            @collector_args = %args;
            return $fake_handle;
        };

        $h->run_on_all({});
    }

    ok(@collector_args, 'spawn was called');
    my %args = @collector_args;
    is($args{new_pgroup},             1,         'new_pgroup set');
    is($args{parent_pids},            [$$],      'parent_pids includes service pid');
    is($args{env_vars}{T2_FORMATTER}, 'Stream2', 'T2_FORMATTER set');
    like($args{loggers}[0][2], qr{\Q$dir\E/runs/.+/.+/0\.jsonl}, 'per-job JSONL path');
    like($args{run_id},        qr/^[0-9A-F-]{36}$/i,             'run_id passed to collector');
    like($args{job_id},        qr/^[0-9A-F-]{36}$/i,             'job_id passed to collector');
    is($args{job_try}, 0, 'job_try passed as 0 to collector');
    ok(!exists $args{env_vars}{T2_IPC_INFO}, 'ipcm_info not in env_vars (not passed to test process)');
    ok($h->{current},                        'current populated');
    is($h->{current}{pid}, 99999, 'current.pid set from handle');

    my $status = $h->request_handler_status;
    ok($status->{running}, 'status reports running job');
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
    select undef, undef, undef, 0.1;

    $h->{current} = {
        run        => $run,
        job        => $job,
        handle     => $fake_handle,
        pid        => $child_pid,
        started_at => time,
    };

    {
        no warnings 'redefine';
        local *Test2::Harness2::Collector::spawn = sub { die "should not relaunch" };
        $h->run_on_all({});
    }

    ok(!$h->{current}, 'current cleared after completion');
    is(scalar @{$run->done}, 1, 'job marked done');
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

    $h->{current} = {
        run        => $run,
        job        => $job,
        handle     => $fake_handle,
        pid        => $child_pid,
        started_at => time,
    };
    push @{$h->{queue}} => $run;

    $h->_perform_hard_stop;

    # Give the OS a moment to finish reaping.
    select undef, undef, undef, 0.1;

    ok(!kill(0, $child_pid), 'child is dead');
    ok(!$h->{current},       'current cleared');
};

subtest 'run_should_end honors state and workers' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $h   = Test2::Harness2->new(workdir => $dir);

    ok(!$h->run_should_end, 'running + empty queue: keep running');

    $h->{state} = 'finishing';
    ok($h->run_should_end, 'finishing + empty queue + no current: end');

    $h->{current} = {pid => 123};
    ok(!$h->run_should_end, 'finishing + current: keep running');

    delete $h->{current};
    $h->{state} = 'terminating';
    ok($h->run_should_end, 'terminating + cleared: end');
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

done_testing;
