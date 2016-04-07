use strict;
use warnings;

use Test2::Util qw/CAN_FORK/;

unless (CAN_FORK) {
    print "1..0 # SKIP cannot fork\n";
    exit 0;
}

my $pid = fork;
die "failed to fork" unless defined $pid;

if ($pid) {
    print "# Parent exits\n";
    exit 0;
}

$| = 1;

print STDERR "# This is a test of a timeout system, the timeout messages are expected.\n";

sleep 2;
print "ok 1 - an event\n";

sleep 2;
print "1..1\n";
