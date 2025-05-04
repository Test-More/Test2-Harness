package App::Yath::Command::ping;
use strict;
use warnings;

our $VERSION = '2.000006';

use App::Yath::Client;

use Time::HiRes qw/sleep time/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Yath',
);

sub args_include_tests { 0 }

sub group { 'daemon' }

sub summary  { "Ping the test runner" }

sub description {
    return <<"    EOT";
This command can be used to test communication with a persistent runner
    EOT
}

sub run {
    my $self = shift;

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

__END__

=head1 POD IS AUTO-GENERATED

