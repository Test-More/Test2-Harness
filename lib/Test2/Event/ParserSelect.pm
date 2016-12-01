package Test2::Event::ParserSelect;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/parser_class/;

sub init {
    my $self = shift;
    defined $self->{+PARSER_CLASS} or $self->trace->throw("'parser_class' is a required attribute");
}

sub summary { 'Selected ' . $_[0]->{+PARSER_CLASS} . ' for parsing' }

1;
