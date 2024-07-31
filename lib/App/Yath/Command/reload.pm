package App::Yath::Command::reload;
use strict;
use warnings;

our $VERSION = '2.000002';

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPCAll',
    'App::Yath::Options::Yath',
);

sub group { 'daemon' }

sub summary { "Reload the persistent test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
Reload the persistent test runner.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    require App::Yath::Client;
    my $client = App::Yath::Client->new(settings => $settings);

    print "Requesting reload...\n";
    $client->reload;
    print "Request sent.\n";

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

