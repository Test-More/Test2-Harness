package App::Yath2::Command::projects;
use strict;
use warnings;

our $VERSION = '2.000011';

use Object::HashBase qw{
    <script
    <config
    <user_config
};

sub argv { $_[0]->{argv} }

sub init {
    my $self = shift;
    $self->{argv} //= [];
    return;
}

# `yath projects` runs a command across a list of project
# directories (useful for CI that tests a set of related repos).
# Stage 13 stubs the command; a proper port has to decide how
# projects are enumerated (config file, directory convention,
# command-line list) and that's not blocking any other stage.
sub run {
    my $self = shift;

    print STDERR "yath projects: not yet implemented in this rewrite.\n";
    print STDERR "See PLAN; a concrete consumer will shape this command's args.\n";

    return 2;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::projects - Run a yath subcommand across a
set of project directories. (Stub.)

=head1 STATUS

Stubbed in Stage 13.

=cut
