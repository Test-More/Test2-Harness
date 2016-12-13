package Test2::Event::UnexpectedProcessExit;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/error file/;

sub init {
    my $self = shift;
    defined $self->{+ERROR} or $self->trace->throw("'error' is a required attribute");
    defined $self->{+FILE} or $self->trace->throw("'file' is a required attribute");
}

sub diagnostics { 1 }

sub summary { $_[0]->{+ERROR} }

1;
