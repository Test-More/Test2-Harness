use Test2::V0 -target => 'Test2::Harness::Collector';
use File::Spec;
use File::Temp qw/tempdir/;
use Time::HiRes qw/time/;

use Test2::Harness::Run;

my $tmp    = tempdir(CLEANUP => 1);
my $run_id = 'test-run';
mkdir(File::Spec->catdir($tmp, $run_id)) or die "Could not create run dir: $!";

sub new_collector {
    return $CLASS->new(
        run     => Test2::Harness::Run->new(run_id => $run_id),
        workdir => $tmp,
        run_id  => $run_id,
        action  => sub { },
        @_,
    );
}

subtest defaults => sub {
    my $one = new_collector();

    is($one->wait_time, 0.02,             "wait_time defaults to 0.02");
    is($one->idle_wait, $CLASS->MIN_WAIT, "backoff starts at the floor");
};

subtest wait_time_is_settable => sub {
    my $one = new_collector(wait_time => 0.5);

    is($one->wait_time, 0.5, "wait_time can be set by the constructor");
};

subtest backoff_doubles_and_caps => sub {
    my $one = new_collector(wait_time => 0.008);

    my @seen;
    for (1 .. 5) {
        push @seen => $one->idle_wait;
        $one->idle_sleep;
    }

    is(
        \@seen,
        [0.001, 0.002, 0.004, 0.008, 0.008],
        "each sleep doubles the wait until it reaches the wait_time ceiling, then holds"
    );

    is($one->idle_wait, 0.008, "wait stays at the ceiling");
};

subtest reset_returns_to_the_floor => sub {
    my $one = new_collector(wait_time => 0.008);

    $one->idle_sleep for 1 .. 4;
    is($one->idle_wait, 0.008, "backed off to the ceiling");

    $one->reset_idle_wait;
    is($one->idle_wait, $CLASS->MIN_WAIT, "reset returns to the floor");
};

subtest ceiling_below_the_floor_is_honored => sub {
    my $one = new_collector(wait_time => 0.0005);

    $one->idle_sleep;
    is($one->idle_wait, 0.0005, "a wait_time under the floor caps the very first backoff");
};

subtest idle_sleep_actually_sleeps => sub {
    my $one = new_collector();

    my $start = time;
    $one->idle_sleep;
    my $slept = time - $start;

    # Deliberately loose: this asserts that a sleep happens at all, not how
    # precisely the scheduler honors the requested duration.
    ok($slept >= 0.0005, "idle_sleep waited", "slept ${slept}s");
};

done_testing;
