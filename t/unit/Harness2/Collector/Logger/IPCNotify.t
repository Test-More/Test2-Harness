use Test2::V0;
use Test2::Harness2::Collector::Logger::IPCNotify;

# ---------------------------------------------------------------------------
# Construction -- required attributes
# ---------------------------------------------------------------------------

subtest 'init - required attributes' => sub {
    like(
        dies { Test2::Harness2::Collector::Logger::IPCNotify->new(ipcm_info => {fake => 1}) },
        qr/service_name.*required/i,
        'missing service_name croaks',
    );

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
    );
    ok($logger, 'constructed with ipcm_info and service_name');
    is($logger->job_try, 0, 'job_try defaults to 0');
    ok(!defined $logger->run_id, 'run_id defaults to undef');
    ok(!defined $logger->job_id, 'job_id defaults to undef');
};

subtest 'set_process_info' => sub {
    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
    );
    $logger->set_process_info(run_id => 'r1', job_id => 'j1', job_try => 2);
    is($logger->run_id,  'r1', 'run_id set via set_process_info');
    is($logger->job_id,  'j1', 'job_id set via set_process_info');
    is($logger->job_try, 2,    'job_try set via set_process_info');

    # Partial update
    $logger->set_process_info(job_try => 9);
    is($logger->run_id,  'r1', 'run_id unchanged after partial update');
    is($logger->job_try, 9,    'job_try updated');
};

subtest 'set_ipcm_info' => sub {
    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
    );
    my $ii = {fake => 2};
    $logger->set_ipcm_info($ii);
    is($logger->ipcm_info, $ii, 'ipcm_info stored via set_ipcm_info');
};

# ---------------------------------------------------------------------------
# log_events() returns false -- we skip per-event callbacks
# ---------------------------------------------------------------------------

subtest 'log_events returns false' => sub {
    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'r1',
        job_id       => 'j1',
    );
    ok(!$logger->log_events, 'log_events is false');
};

# ---------------------------------------------------------------------------
# shutdown() sends the right IPC message
# ---------------------------------------------------------------------------

subtest 'shutdown sends test_complete' => sub {
    my @sent;

    # Build a fake client that records send_message calls.
    my $fake_client = bless {}, 'FakeIPCClient';
    no warnings 'once';
    *FakeIPCClient::send_message = sub {
        my ($self, $to, $content) = @_;
        push @sent => {to => $to, content => $content};
        return;
    };

    # Build a fake handle whose client() returns our fake client.
    my $fake_handle = bless {}, 'FakeIPCHandle';
    *FakeIPCHandle::client = sub { $fake_client };

    # Intercept IPC::Manager::Service::Handle->new to return our fake.
    local *IPC::Manager::Service::Handle::new = sub { $fake_handle };

    # Fake auditor that reports passing so the logger can fill pass=1.
    my $fake_auditor = bless {}, 'FakeAuditor';
    *FakeAuditor::failing = sub { 0 };

    # Fake collector carrying a _child_exit wait-status of 2 << 8 (exit code 2).
    my $fake_collector = {_child_exit => (2 << 8)};

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'run-123',
        job_id       => 'job-456',
        job_try      => 2,
        auditor      => $fake_auditor,
    );

    $logger->shutdown($fake_collector);

    is(scalar @sent, 1, 'one send_message call');
    is(
        $sent[0],
        {
            to      => 'harness',
            content => {
                kind      => 'test_complete',
                run_id    => 'run-123',
                job_id    => 'job-456',
                job_try   => 2,
                pass      => 1,
                exit_code => 2,
                exit_sig  => 0,
            },
        },
        'payload shape includes pass/exit_code',
    );
};

# ---------------------------------------------------------------------------
# shutdown() caches the handle -- only one new() call for multiple shutdowns
# ---------------------------------------------------------------------------

subtest 'handle is lazily built and cached' => sub {
    my $new_count   = 0;
    my $fake_client = bless {}, 'FakeIPCClient2';
    no warnings 'once';
    *FakeIPCClient2::send_message = sub { };
    my $fake_handle = bless {}, 'FakeIPCHandle2';
    *FakeIPCHandle2::client = sub { $fake_client };

    local *IPC::Manager::Service::Handle::new = sub { $new_count++; $fake_handle };

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'r1',
        job_id       => 'j1',
    );

    $logger->shutdown;
    $logger->shutdown;

    is($new_count, 1, 'Handle->new called only once even across two shutdowns');
};

# ---------------------------------------------------------------------------
# shutdown() warns on IPC failure, does not propagate
# ---------------------------------------------------------------------------

subtest 'shutdown warns on IPC failure, does not die' => sub {
    local *IPC::Manager::Service::Handle::new = sub {
        die "connection refused\n";
    };

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'r1',
        job_id       => 'j1',
    );

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $ok  = eval { $logger->shutdown; 1 };
    my $err = $@;

    ok($ok,   'shutdown does not propagate the exception');
    ok(!$err, 'no exception escaped');
    is(scalar @warnings, 1, 'exactly one warning emitted');
    like($warnings[0], qr/IPCNotify shutdown failed/, 'warning mentions IPCNotify shutdown');
};

# ---------------------------------------------------------------------------
# startup() and log_event() are no-ops
# ---------------------------------------------------------------------------

subtest 'startup and log_event are no-ops' => sub {
    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'r1',
        job_id       => 'j1',
    );

    ok(lives { $logger->startup },       'startup lives');
    ok(lives { $logger->log_event({}) }, 'log_event lives');
};

# ---------------------------------------------------------------------------
# depends_on returns empty list
# ---------------------------------------------------------------------------

subtest 'depends_on returns empty list' => sub {
    my @deps = Test2::Harness2::Collector::Logger::IPCNotify->depends_on;
    is(\@deps, [], 'depends_on returns empty list');
};

subtest 'ipcm_info is required at construction' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Logger::IPCNotify->new(service_name => 'harness'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

done_testing;
