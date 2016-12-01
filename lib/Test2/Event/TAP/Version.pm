package Test2::Event::TAP::Version;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/version/;

sub init {
    my $self = shift;
    defined $self->{+VERSION} or $self->trace->throw("'version' is a required attribute");
}

sub summary { 'Producer is using TAP version ' . $_[0]->{+VERSION} . '.' }

1;
