package TestBarrier;
use strict;
use warnings;

use Time::HiRes qw/sleep time/;

use Exporter qw/import/;

our @EXPORT_OK = qw/barrier_wait/;

# Fixtures that have to be running at the same time as their siblings used to
# sleep and hope the overlap landed inside the sleep. That makes the fixture
# slow, and it makes the assertion a coin flip on a machine slow enough to
# spend the whole sleep starting the next job.
#
# This makes the overlap a fact instead: every participant records that it
# arrived, then waits until as many participants have arrived as the run
# expects.
#
# Markers are never removed. A participant that starts after enough others
# have already arrived therefore does not wait at all, which is what keeps a
# run with more tests than slots from stalling on its last, unpaired test.
sub barrier_wait {
    my %params = @_;

    my $dir = $params{dir} // $ENV{TEST_BARRIER_DIR}
        or die "No barrier directory (pass one, or set TEST_BARRIER_DIR)";

    my $want = $params{count} // $ENV{TEST_BARRIER_COUNT} // 2;

    # A ceiling, not a wait. It only comes into play when something is wrong
    # and the other participants are never going to arrive; reaching it fails
    # the assertion the barrier exists to make, which is the point.
    my $ceiling = $params{ceiling} // $ENV{TEST_BARRIER_CEILING} // 30;

    open(my $fh, '>', "$dir/$$") or die "Could not write barrier marker: $!";
    close($fh);

    my $start = time;
    while (1) {
        opendir(my $dh, $dir) or die "Could not open barrier dir '$dir': $!";
        my $have = grep { !m/^\.\.?$/ } readdir($dh);
        closedir($dh);

        return $have if $have >= $want;
        return $have if time - $start > $ceiling;

        sleep 0.05;
    }
}

1;
