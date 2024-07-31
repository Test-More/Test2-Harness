package App::Yath::Command::status;
use strict;
use warnings;

our $VERSION = '2.000002';

use Term::Table();

use Test2::Harness::Util qw/render_status_data/;

use parent 'App::Yath::Command';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;
include_options(
    'App::Yath::Options::IPCAll',
    'App::Yath::Options::Yath',
);

sub group { 'state' }

sub summary { "Status info and process lists for the runner" }
sub cli_args { "" }

sub description {
    return <<"    EOT";
This command will provide health details and a process list for the runner.
    EOT
}

sub run {
    my $self = shift;

    my $settings = $self->settings;

    require App::Yath::Client;
    my $client = App::Yath::Client->new(settings => $settings);

    my $data = $client->overall_status;
    my $text = render_status_data($data);
    print "\n$text\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED

