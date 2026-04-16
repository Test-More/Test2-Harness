use Test2::V0;
use Test2::Harness2::Collector::Logger::IPCNotify;

# ---------------------------------------------------------------------------
# Construction -- required attributes
# ---------------------------------------------------------------------------

subtest 'init - required attributes' => sub {
    like(
        dies { Test2::Harness2::Collector::Logger::IPCNotify->new() },
        qr/ipcm_info.*required/i,
        'missing ipcm_info croaks',
    );

    like(
        dies {
            Test2::Harness2::Collector::Logger::IPCNotify->new(
                ipcm_info => {},
            );
        },
        qr/service_name.*required/i,
        'missing service_name croaks',
    );

    like(
        dies {
            Test2::Harness2::Collector::Logger::IPCNotify->new(
                ipcm_info    => {},
                service_name => 'harness',
            );
        },
        qr/run_id.*required/i,
        'missing run_id croaks',
    );

    like(
        dies {
            Test2::Harness2::Collector::Logger::IPCNotify->new(
                ipcm_info    => {},
                service_name => 'harness',
                run_id       => 'r1',
            );
        },
        qr/job_id.*required/i,
        'missing job_id croaks',
    );

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'r1',
        job_id       => 'j1',
    );
    ok($logger, 'constructed with required attrs');
    is($logger->job_try, 0, 'job_try defaults to 0');
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

subtest 'shutdown sends job_complete_notify' => sub {
    my @sent;

    # Build a fake handle that records sync_request calls.
    my $fake_handle = bless {}, 'FakeIPCHandle';
    no warnings 'once';
    *FakeIPCHandle::sync_request = sub {
        my ($self, $payload) = @_;
        push @sent => $payload;
        return {ok => 1};
    };

    # Intercept IPC::Manager::Service::Handle->new to return our fake.
    local *IPC::Manager::Service::Handle::new = sub { $fake_handle };

    my $logger = Test2::Harness2::Collector::Logger::IPCNotify->new(
        ipcm_info    => {fake => 1},
        service_name => 'harness',
        run_id       => 'run-123',
        job_id       => 'job-456',
        job_try      => 2,
    );

    $logger->shutdown;

    is(scalar @sent, 1, 'one sync_request call');
    is(
        $sent[0],
        {
            request => 'job_complete_notify',
            run_id  => 'run-123',
            job_id  => 'job-456',
            job_try => 2,
        },
        'payload shape is correct',
    );
};

# ---------------------------------------------------------------------------
# shutdown() caches the handle -- only one new() call for multiple shutdowns
# ---------------------------------------------------------------------------

subtest 'handle is lazily built and cached' => sub {
    my $new_count   = 0;
    my $fake_handle = bless {}, 'FakeIPCHandle2';
    no warnings 'once';
    *FakeIPCHandle2::sync_request = sub { {ok => 1} };

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

done_testing;
