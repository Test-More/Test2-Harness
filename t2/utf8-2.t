use utf8;
use strict;
use warnings;
use Test::More;
use Test2::Plugin::UTF8;
use Test2::API qw/test2_stack/;
use Test2::Harness::Util::JSON qw/decode_json/;
use Test2::Tools::Basic qw/skip_all/;
use File::Spec;
use Test2::Util qw/get_tid ipc_separator/;
# HARNESS-DURATION-SHORT
# HARNESS-NO-IO-EVENTS
# HARNESS-USE-COLLECTOR-ECHO

skip_all "This test must run under Test2::Harness"
    unless $ENV{TEST2_HARNESS_ACTIVE};

skip_all "No echo file set"
    unless $ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE};

test2_stack()->top;
my ($hub) = test2_stack()->all();
my $fmt = $hub->format;
skip_all "This test requires the stream formatter"
    unless $fmt && $fmt->isa('Test2::Formatter::Stream');

print STDOUT "THIS-STDOUT: Mākaha\n";
note "THIS-NOTE: Mākaha";
ok(1, "THIS-ASSERT: Mākaha");

open(my $fh, '<', $ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE}) or die "Could not open file '$ENV{TEST2_HARNESS_COLLECTOR_ECHO_FILE}': $!";

my %found;
FOUND: while (1) {
    seek($fh, 0, 1);
    my $pos = tell($fh);
    while (my $line = <$fh>) {
        unless ($line =~ m/\n/) {
            seek($fh, $pos, 0);
            last;
        }
        next unless $line =~ m/THIS-(STDOUT|NOTE|ASSERT)/;
        $found{$1} = decode_json($line);
    }

    last if $found{STDOUT} && $found{NOTE} && $found{ASSERT};

    sleep 0.2;
}

like($found{STDOUT}->{facet_data}->{info}->[0]->{details}, qr/\QMākaha\E/, "STDOUT looks correct");
like($found{NOTE}->{facet_data}->{info}->[0]->{details},   qr/\QMākaha\E/, "NOTE looks correct");
like($found{ASSERT}->{facet_data}->{assert}->{details},    qr/\QMākaha\E/, "NOTE looks correct");

done_testing;
