use Test2::V0 -target => 'Test2::Harness::Instance';
use File::Temp qw/tempfile/;

# Build minimal mock collaborators for the Instance constructor.
# Instance requires: log_file, scheduler (with runner/set_runner), runner, ipc.

sub make_mock_runner {
    return mock {} => (
        add => [
            terminated    => sub { 0 },
            terminate     => sub { 1 },
            process_list  => sub { () },
            overall_status => sub { [] },
            abort         => sub { 1 },
            stop          => sub { 1 },
            kill          => sub { 1 },
            reload        => sub { 0 },
            blacklist     => sub { {} },
            job_update    => sub { 1 },
            set_runner    => sub { },
            runner        => sub { undef },
        ],
    );
}

sub make_mock_scheduler {
    my ($runner_mock) = @_;
    return mock {} => (
        add => [
            runner        => sub { undef },
            set_runner    => sub { },
            terminated    => sub { 0 },
            terminate     => sub { 1 },
            process_list  => sub { () },
            overall_status => sub { [] },
            abort         => sub { 1 },
            stop          => sub { 1 },
            kill          => sub { 1 },
            advance       => sub { 0 },
            queue_run     => sub { 1 },
            start         => sub { 1 },
            job_update    => sub { 1 },
        ],
    );
}

sub make_mock_ipc {
    return mock {} => (
        add => [
            terminate  => sub { 1 },
            protocol   => sub { 'Test2::Harness::IPC::Protocol::AtomicPipe' },
            callback   => sub { sub {} },
        ],
    );
}

sub make_instance {
    my %extra = @_;
    my ($fh, $log_file) = tempfile(UNLINK => 1);
    close $fh;
    my $runner    = make_mock_runner();
    my $scheduler = make_mock_scheduler();
    my $ipc       = make_mock_ipc();
    return $CLASS->new(
        log_file  => $log_file,
        scheduler => $scheduler,
        runner    => $runner,
        ipc       => $ipc,
        %extra,
    );
}

subtest 'required attributes' => sub {
    my ($fh, $log_file) = tempfile(UNLINK => 1);
    close $fh;
    my $runner    = make_mock_runner();
    my $scheduler = make_mock_scheduler();
    my $ipc       = make_mock_ipc();

    like(
        dies {
            $CLASS->new(scheduler => $scheduler, runner => $runner, ipc => $ipc)
        },
        qr/log_file.*required/i,
        'log_file is required',
    );
    like(
        dies {
            $CLASS->new(log_file => $log_file, runner => $runner, ipc => $ipc)
        },
        qr/scheduler.*required/i,
        'scheduler is required',
    );
    like(
        dies {
            $CLASS->new(log_file => $log_file, scheduler => $scheduler, ipc => $ipc)
        },
        qr/runner.*required/i,
        'runner is required',
    );
    like(
        dies {
            $CLASS->new(log_file => $log_file, scheduler => $scheduler, runner => $runner)
        },
        qr/ipc.*required/i,
        'ipc is required',
    );
};

subtest 'basic construction' => sub {
    my $inst = make_instance();
    ok($inst->isa($CLASS), 'creates instance');
    ok($inst->log_file,  'log_file accessible');
    ok($inst->runner,    'runner accessible');
    ok($inst->scheduler, 'scheduler accessible');
    ok($inst->ipc,       'ipc accessible (wrapped in arrayref)');
};

subtest 'ipc wrapped in arrayref when scalar provided' => sub {
    my $inst = make_instance();
    ref_ok($inst->{ipc}, 'ARRAY', 'ipc stored as arrayref');
};

subtest 'api_ping returns pong' => sub {
    my $inst = make_instance();
    is($inst->api_ping, 'pong', 'api_ping returns "pong"');
};

subtest 'api_pid returns current PID' => sub {
    my $inst = make_instance();
    is($inst->api_pid, $$, 'api_pid returns current PID');
};

subtest 'api_log_file returns log file path' => sub {
    my $inst = make_instance();
    is($inst->api_log_file, $inst->log_file, 'api_log_file returns log_file');
};

subtest 'handle_request — success path' => sub {
    my $inst = make_instance();
    require Test2::Harness::Instance::Request;
    my $req = Test2::Harness::Instance::Request->new(
        request_id => 'req-ping',
        api_call   => 'ping',
    );
    my $res = $inst->handle_request($req);
    ok($res->isa('Test2::Harness::Instance::Response'), 'returns Response object');
    is($res->success,  1,      'success is 1');
    is($res->response, 'pong', 'response contains pong');
};

subtest 'handle_request — error path for unknown api_call' => sub {
    my $inst = make_instance();
    require Test2::Harness::Instance::Request;
    my $req = Test2::Harness::Instance::Request->new(
        request_id => 'req-bad',
        api_call   => 'no_such_api_call',
    );
    my $res = $inst->handle_request($req);
    ok($res->isa('Test2::Harness::Instance::Response'), 'returns Response on error');
    is($res->success, 0, 'success is 0 for unknown api call');
    ok($res->api->{error}, 'error message present');
};

subtest 'parse_request_args' => sub {
    my $inst = make_instance();

    is([$inst->parse_request_args(undef)],   [],             'undef returns empty list');
    is([$inst->parse_request_args('hello')], ['hello'],      'scalar returned as list with one element');
    is([$inst->parse_request_args([1, 2])],  [1, 2],         'arrayref flattened to list');
    is([$inst->parse_request_args({a => 1})], ['a', 1],      'hashref flattened to key-value pairs');
};

subtest 'terminate — first reason wins' => sub {
    my $inst = make_instance();
    ok(!$inst->terminated, 'not terminated initially');
    $inst->terminate('first-reason');
    is($inst->terminated, 1, 'terminated set after first call');
    $inst->terminate('second-reason');
    is($inst->terminated, 1, 'terminated not overwritten by second call');
};

subtest 'stop sets stop flag' => sub {
    my $inst = make_instance();
    ok(!$inst->{stop}, 'stop not set initially');
    $inst->stop;
    ok($inst->{stop}, 'stop set after calling stop()');
};

done_testing;
