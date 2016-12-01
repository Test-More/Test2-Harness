package Test2::Event::ProcessStart;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/file/;

sub init {
    my $self = shift;
    defined $self->{+FILE} or $self->trace->throw("'file' is a required attribute");
}

sub summary { 'Started process with ' . $_[0]->{+FILE} }

1;
