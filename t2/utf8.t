use utf8;
use Test2::V0;
use Test2::Plugin::UTF8;
use Test2::API qw/test2_stack/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Util qw/get_tid ipc_separator/;
use Time::HiRes qw/sleep/;
# HARNESS-DURATION-SHORT
# HARNESS-USE-COLLECTOR-ECHO

test2_stack()->top;
my ($hub) = test2_stack()->all();
my $fmt = $hub->format;
skip_all "This test must run under Test2::Harness"
    unless $ENV{TEST2_HARNESS_ACTIVE};

skip_all "No echo file set"
    unless $ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE};

ok(1, "І ще трохи");

open(my $fh, '<', $ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE}) or die "Could not open file '$ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE}': $!";

my $event;
FOUND: while (1) {
    seek($fh, 0, 1);
    my $pos = tell($fh);
    while (my $line = <$fh>) {
        unless ($line =~ m/\n/) {
            seek($fh, $pos, 0);
            last;
        }

        $event = decode_json($line);
        last FOUND if $event->{facet_data}->{assert};
    }

    sleep 0.2;
}

like($event->{facet_data}->{assert}->{details}, qr/\QІ ще трохи\E/, "Wrote utf8, not double encoded");

done_testing;
