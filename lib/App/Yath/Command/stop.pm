package App::Yath::Command::stop;
use strict;
use warnings;

our $VERSION = '2.000006';

use App::Yath::Client;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

sub group { 'daemon' }

sub summary { "Wait for running tests to complete, then end runner and abort any pending tests" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will kill the active yath runner and any running or pending tests.
    EOT
}

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPC',
    'App::Yath::Options::Yath',
);

sub run {
    my $self = shift;

    my $settings = $self->settings;
    my $client = App::Yath::Client->new(settings => $settings);

    $client->stop();

    return 0;
}

1;

__END__

=head1 POD IS AUTO-GENERATED


