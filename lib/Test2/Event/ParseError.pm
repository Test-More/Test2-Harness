package Test2::Event::ParseError;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/parse_error/;

sub init {
    my $self = shift;
    defined $self->{+PARSE_ERROR} or $self->trace->throw("'parse_error' is a required attribute");
}

sub causes_fail { 1 }
sub diagnostics { 1 }

sub summary { 'Error parsing output from a test file: ' . $_[0]->{+PARSE_ERROR} }

1;
