use Test2::V0;

use File::Spec;

use App::Yath::Tester qw/yath/;
use Test2::Harness::Util::File::JSONL;

my $dir = __FILE__;
$dir =~ s{\.t$}{}g;
$dir =~ s{^\./}{};

# HARNESS-SHARES-DB tests may run alongside each other, but never alongside a
# HARNESS-CONFLICTS-DB test. Read the window each test was live for out of the
# log and check which windows were allowed to overlap.
yath(
    command => 'test',
    args    => [$dir, '--ext=tx', '-j4'],
    log     => 1,
    exit    => 0,
    test    => sub {
        my $out = shift;
        my $log = $out->{log};

        my (%name, %start, %stop);

        my @events = $log->poll();
        while (@events) {
            if (my $event = shift @events) {
                my $f      = $event->{facet_data};
                my $job_id = $event->{job_id} // next;

                if (my $s = $f->{harness_job_start}) {
                    $name{$job_id}  = (File::Spec->splitpath($s->{rel_file}))[-1];
                    $start{$job_id} = $s->{stamp};
                }

                if (my $e = $f->{harness_job_exit}) {
                    $stop{$job_id} = $e->{stamp};
                }
            }

            # Check for additional events, probably should not have any, but we
            # may hit a buffering limit in the log reader and need additional
            # polls.
            push @events => $log->poll;
        }

        my %window;
        for my $job_id (keys %name) {
            $window{$name{$job_id}} = [$start{$job_id}, $stop{$job_id}];
        }

        is([sort keys %window], [sort qw/exclusive.tx shared_a.tx shared_b.tx/], "Found all three tests in the log");

        my $overlap = sub {
            my ($x, $y) = @_;
            my ($xa, $xb) = @{$window{$x}};
            my ($ya, $yb) = @{$window{$y}};
            return $xa < $yb && $ya < $xb;
        };

        ok(!$overlap->('exclusive.tx', 'shared_a.tx'), "exclusive did not run alongside shared_a");
        ok(!$overlap->('exclusive.tx', 'shared_b.tx'), "exclusive did not run alongside shared_b");
        ok($overlap->('shared_a.tx', 'shared_b.tx'),   "the two shared tests did run alongside each other");
    },
);

done_testing;
