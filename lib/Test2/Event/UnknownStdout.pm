package Test2::Event::UnknownStdout;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/output/;

sub init {
    my $self = shift;
    defined $self->{+OUTPUT} or $self->trace->throw("'output' is a required attribute");
}

sub diagnostics { 0 }

sub from_handle { 'STDOUT' }

sub summary { $_[0]->{+OUTPUT} }

1;
