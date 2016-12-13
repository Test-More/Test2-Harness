package Test2::Event::UnknownStderr;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/output/;

sub init {
    my $self = shift;
    defined $self->{+OUTPUT} or $self->trace->throw("'output' is a required attribute");
}

sub diagnostics { 1 }

sub summary { $_[0]->{+OUTPUT} }

1;
