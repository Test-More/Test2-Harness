package App::Yath2::Command::do;
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

# `yath do ALIAS [ARGS...]` dispatches to an alias defined in the
# project's .yath.rc. Stage 13 stubs this: alias resolution is
# config-shape-dependent, and the config layer doesn't have an
# opinion on aliases yet.
sub run {
    my $self = shift;

    print STDERR "yath do: not yet implemented in this rewrite.\n";
    print STDERR "Alias resolution waits on a richer .yath.rc / config loader.\n";

    return 2;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Command::do - Dispatch a user-defined alias. (Stub.)

=head1 STATUS

Stubbed in Stage 13.

=cut
