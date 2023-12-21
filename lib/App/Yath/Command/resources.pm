package App::Yath::Command::resources;
use strict;
use warnings;

our $VERSION = '2.000000';

use Term::Table();
use File::Spec();
use Time::HiRes qw/sleep/;

use App::Yath::Client;
use Test2::Harness::Util qw/mod2file render_status_data/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPCAll',
    'App::Yath::Options::Yath',
);

sub group { 'state' }

sub summary { "View the state info for a test runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
A look at the state and resources used by a runner.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    my $client = App::Yath::Client->new(settings => $settings);

    return 0 if eval {
        while (1) { $self->render($client); sleep 0.1 }

        1;
    };

    die $@ unless $@ =~ m/Disconnected pipe/;

    print "\n*** Disconnected from harness ***\n\n";

    return 0;
}

sub render {
    my $self = shift;
    my ($client) = @_;

    my @out = (
        "\r\e[2J\r\e[1;1H",
        "\n", $client->ipc_text, "\n",
        "\n==== Resource state ====\n",
    );

    my $resources = $client->resources;

    for my $resource (@$resources) {
        my ($class, $data) = @$resource;
        next unless $data;

        my $text = render_status_data($data);
        push @out => "\nResource: $class\n$text\n";
    }

    print @out;
}

1;

__END__

=head1 POD IS AUTO-GENERATED

