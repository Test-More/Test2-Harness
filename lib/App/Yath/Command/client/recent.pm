package App::Yath::Command::client::recent;
use strict;
use warnings;

our $VERSION = '2.000000';

use parent 'App::Yath::Command::recent';
use Test2::Harness::Util::HashBase;

use Getopt::Yath;

include_options(
    'App::Yath::Options::Yath',
    'App::Yath::Options::Recent',
    'App::Yath::Options::WebClient',
);

sub summary { "Show a list of recent runs on a yath server" }

sub description {
    return <<"    EOT";
This command will find the last several runs from a yath server
    EOT
}

sub get_data {
    my $self = shift;
    my ($project, $count, $user) = @_;

    return $self->get_from_http($project, $count, $user) // die "Could not get data from the server.\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED
