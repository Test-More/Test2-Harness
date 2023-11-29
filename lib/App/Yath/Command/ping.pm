package App::Yath::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000000';

use App::Yath::Client;

use Time::HiRes qw/sleep time/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Yath',
);

sub starts_runner            { 0 }
sub starts_persistent_runner { 0 }

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary  { "Ping the test runner" }

warn "FIXME";
sub description {
    return <<"    EOT";
    FIXME
    EOT
}

sub run {
    my $self = shift;

    warn "Fix this";
    $0 = "yath";

    my $client = App::Yath::Client->new(settings => $self->{+SETTINGS});

    while (1) {
        my $start = time;
        print "\n=== ping ===\n";
        my $res = $client->ping();

        print "=== $res ===\n";
        print "=== " . sprintf("%-02.4f", time - $start) . " ===\n";

        sleep 4;
    }

    return 0;
}

1;
