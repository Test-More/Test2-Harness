use Test2::V0;

use File::Temp qw/tempdir/;
use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

use Test2::Harness::Util::JSON qw/decode_json/;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# The order jobs start and stop in is not fixed: a machine slow enough to take
# longer starting a job than a job takes to run will interleave them
# differently every time. What is fixed is how many the scheduler allows at
# once, and the fixtures hold each other until that many are live so the log
# is guaranteed to show it rather than merely likely to.
sub concurrency {
    my ($log) = @_;

    my @order;
    my @events = $log->poll();
    while (@events) {
        if (my $event = shift @events) {
            my $f = $event->{facet_data};

            if (my $e = $f->{harness_job_exit}) {
                push @order => [$e->{stamp}, -1];
            }

            if (my $l = $f->{harness_job_start}) {
                push @order => [$l->{stamp}, 1];
            }
        }

        # Check for additional events, probably should not have any, but we may hit
        # a buffering limit in the log reader and need additional polls.
        push @events => $log->poll;
    }

    # We care about the order in which events happened based on time stamp, not
    # the order in which they were collected, which may be different. A start
    # and an exit that share a stamp are counted as the exit first, so a slow
    # clock cannot inflate the count.
    @order = sort { $a->[0] <=> $b->[0] || $a->[1] <=> $b->[1] } @order;

    my ($running, $max, $starts, $exits) = (0, 0, 0, 0);
    for my $item (@order) {
        my $delta = $item->[1];

        $running += $delta;
        $max = $running if $running > $max;

        $delta > 0 ? $starts++ : $exits++;
    }

    return {max => $max, starts => $starts, exits => $exits};
}

# Each run gets its own barrier directory: markers left by an earlier run
# would let a later one satisfy its barrier without ever overlapping.
run_at(4);
run_at(2);

sub run_at {
    my ($jobs) = @_;

    my $barrier = tempdir(CLEANUP => 1);

    yath(
        command => 'test',
        args    => [
            $dir, '--ext=tx', "-j$jobs",
            '-It/lib',
            '--env-var' => "TEST_BARRIER_DIR=$barrier",
            '--env-var' => "TEST_BARRIER_COUNT=$jobs",
        ],
        log     => 1,
        exit    => 0,
        test    => sub {
            my $out = shift;
            my $stats = concurrency($out->{log});

            is($stats->{starts}, 5, "All 5 tests started");
            is($stats->{exits},  5, "All 5 tests exited");

            # The barrier holds every job in the wave until the full $jobs of them
            # are live, so this is exact now, not a range: fewer means the limiter
            # or the barrier failed, more means the limiter did.
            is($stats->{max}, $jobs, "Ran exactly $jobs jobs at once, never more");
        },
    );
}

done_testing;
