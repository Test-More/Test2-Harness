package Test2::Event::UnexpectedProcessExit;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/error/;

sub init {
    my $self = shift;
    defined $self->{+ERROR} or $self->trace->throw("'error' is a required attribute");
}

sub causes_fail { 0 }
sub diagnostics { 1 }

sub summary { $_[0]->{+ERROR} }

1;
