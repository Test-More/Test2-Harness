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
# differently every time. What is fixed is that the scheduler never runs more
# jobs at once than it was told to, and that it does run more than one.
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

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j4'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $stats = concurrency($out->{log});

        is($stats->{starts}, 5, "All 5 tests started");
        is($stats->{exits},  5, "All 5 tests exited");

        ok($stats->{max} <= 4, "Never ran more than 4 jobs at once") or diag("max: $stats->{max}");
        ok($stats->{max} > 1,  "Ran more than one job at once")      or diag("max: $stats->{max}");
    },
);

yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j2'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $stats = concurrency($out->{log});

        is($stats->{starts}, 5, "All 5 tests started");
        is($stats->{exits},  5, "All 5 tests exited");

        ok($stats->{max} <= 2, "Never ran more than 2 jobs at once") or diag("max: $stats->{max}");
        ok($stats->{max} > 1,  "Ran more than one job at once")      or diag("max: $stats->{max}");
    },
);

done_testing;
