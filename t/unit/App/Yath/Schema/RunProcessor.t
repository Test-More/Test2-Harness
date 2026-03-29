use Test2::V0;

# Test exponential backoff behavior in retry_on_disconnect
# We can't easily construct a full RunProcessor (needs DB config),
# so we test the backoff logic by mocking the object minimally.

use List::Util qw/min/;

subtest 'exponential backoff delay calculation' => sub {
    # Replicate the delay formula from retry_on_disconnect:
    #   base_delay = min(30, 2 ** ($attempt - 1))
    #   delay = base_delay * (0.5 + rand(0.5))

    # Verify base delays follow the expected doubling pattern
    my @expected_base = (1, 2, 4, 8, 16, 30, 30, 30);
    for my $attempt (1 .. 8) {
        my $base = min(30, 2 ** ($attempt - 1));
        is($base, $expected_base[$attempt - 1], "attempt $attempt: base delay is $expected_base[$attempt - 1]s");
    }

    # Verify jitter range: delay should be in [base*0.5, base*1.0)
    srand(42);
    for my $attempt (1 .. 5) {
        my $base = min(30, 2 ** ($attempt - 1));
        for (1 .. 20) {
            my $delay = $base * (0.5 + rand(0.5));
            ok($delay >= $base * 0.5, "attempt $attempt: delay >= ${\ ($base * 0.5)}");
            ok($delay < $base * 1.0, "attempt $attempt: delay < $base");
        }
    }
};

subtest 'retry_on_disconnect succeeds on first try' => sub {
    # Minimal mock of RunProcessor to test retry_on_disconnect directly
    my $mock_schema = mock {} => (
        add => [
            storage => sub {
                mock {} => (
                    add => [
                        disconnect       => sub { },
                        ensure_connected => sub { },
                    ],
                );
            },
        ],
    );

    # Build a minimal "self" hash with the constants we need
    my $call_count = 0;
    my $self = bless {
        disconnect_retry => 15,
    }, 'App::Yath::Schema::RunProcessor';

    # We need the real method, so load the module (but skip init)
    require App::Yath::Schema::RunProcessor;

    # Mock schema() on the object
    my $rp_mock = mock 'App::Yath::Schema::RunProcessor' => (
        override => [
            schema => sub { $mock_schema },
        ],
    );

    my $result = $self->retry_on_disconnect("test op" => sub { $call_count++; 1 });
    is($result, 1, "returns 1 on success");
    is($call_count, 1, "callback called exactly once on success");
};

subtest 'retry_on_disconnect retries on disconnect error' => sub {
    require App::Yath::Schema::RunProcessor;

    my @sleep_args;
    # sleep was imported into RunProcessor's namespace, so mock it there
    my $sleep_mock = mock 'App::Yath::Schema::RunProcessor' => (
        override => [
            sleep => sub { push @sleep_args, $_[0] },
        ],
    );

    my $mock_storage = mock {} => (
        add => [
            disconnect       => sub { },
            ensure_connected => sub { },
        ],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
        ],
    );

    my $rp_mock = mock 'App::Yath::Schema::RunProcessor' => (
        override => [
            schema => sub { $mock_schema },
        ],
    );

    my $call_count = 0;
    my $self = bless { disconnect_retry => 5 }, 'App::Yath::Schema::RunProcessor';

    # Fail twice with "gone away", then succeed
    my $result = $self->retry_on_disconnect(
        "test reconnect" => sub {
            $call_count++;
            die "Server has gone away" if $call_count <= 2;
            return 1;
        },
    );

    is($result, 1, "succeeds after retries");
    is($call_count, 3, "callback called 3 times (2 failures + 1 success)");

    # First failure (attempt=0) skips sleep (goes straight to ensure_connected)
    # Second failure (attempt=1) does disconnect + sleep with base=1s
    is(scalar @sleep_args, 1, "slept once (attempt 0 skips sleep, attempt 1 sleeps)");

    # Verify exponential backoff: attempt 1 -> base_delay=2^0=1s, jitter in [0.5, 1.0)
    ok($sleep_args[0] >= 0.5 && $sleep_args[0] < 1.0, "sleep in [0.5, 1.0): got $sleep_args[0]");
};

subtest 'retry_on_disconnect backoff increases with attempts' => sub {
    require App::Yath::Schema::RunProcessor;

    my @sleep_args;
    my $sleep_mock = mock 'App::Yath::Schema::RunProcessor' => (
        override => [
            sleep => sub { push @sleep_args, $_[0] },
        ],
    );

    my $mock_storage = mock {} => (
        add => [
            disconnect       => sub { },
            ensure_connected => sub { },
        ],
    );
    my $mock_schema = mock {} => (
        add => [
            storage => sub { $mock_storage },
        ],
    );

    my $rp_mock = mock 'App::Yath::Schema::RunProcessor' => (
        override => [
            schema => sub { $mock_schema },
        ],
    );

    my $call_count = 0;
    my $self = bless { disconnect_retry => 6 }, 'App::Yath::Schema::RunProcessor';

    # Fail 4 times, then succeed on 5th
    my $result = $self->retry_on_disconnect(
        "test backoff" => sub {
            $call_count++;
            die "Server has gone away" if $call_count <= 4;
            return 1;
        },
    );

    is($result, 1, "succeeds after 4 retries");
    is($call_count, 5, "callback called 5 times");

    # Sleeps happen on attempts 1,2,3 (attempt 0 skips sleep)
    is(scalar @sleep_args, 3, "slept 3 times");

    # Verify increasing delays (regardless of jitter, each should be > previous minimum)
    # attempt 1: base=1, range [0.5, 1.0)
    # attempt 2: base=2, range [1.0, 2.0)
    # attempt 3: base=4, range [2.0, 4.0)
    ok($sleep_args[0] >= 0.5,  "sleep 1 >= 0.5");
    ok($sleep_args[0] < 1.0,   "sleep 1 < 1.0");
    ok($sleep_args[1] >= 1.0,  "sleep 2 >= 1.0");
    ok($sleep_args[1] < 2.0,   "sleep 2 < 2.0");
    ok($sleep_args[2] >= 2.0,  "sleep 3 >= 2.0");
    ok($sleep_args[2] < 4.0,   "sleep 3 < 4.0");
};

done_testing;
