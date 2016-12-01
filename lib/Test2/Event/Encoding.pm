package Test2::Event::Encoding;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/encoding/;

sub init {
    my $self = shift;
    defined $self->{+ENCODING} or $self->trace->throw("'encoding' is a required attribute");
}

sub summary { 'Set parser encoding to ' . $_[0]->{+ENCODING} }

1;
