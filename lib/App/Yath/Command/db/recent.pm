package App::Yath::Command::db::recent;
use strict;
use warnings;

our $VERSION = '2.000007';

use parent 'App::Yath::Command::recent';
use Test2::Harness::Util::HashBase;

sub group   { ["database", 'history'] }
sub summary { "Show a list of recent runs in the database" }

sub description {
    return <<"    EOT";
This command will find the last several runs from a yath database.
    EOT
}

sub get_data {
    my $self = shift;
    my ($project, $count, $user) = @_;

    return $self->get_from_db($project, $count, $user) // die "Could not get data from the database.\n";
}

1;

__END__

=head1 POD IS AUTO-GENERATED
