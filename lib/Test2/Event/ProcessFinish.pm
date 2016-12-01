package Test2::Event::ProcessFinish;
use strict;
use warnings;

our $VERSION = '0.000012';

BEGIN { require Test2::Event; our @ISA = qw(Test2::Event) }
use Test2::Util::HashBase qw/file result/;

sub init {
    my $self = shift;
    defined $self->{+RESULT} or $self->trace->throw("'result' is a required attribute");
}

sub summary {
    my $self = shift;
    return $self->{+FILE} . ' ' . ($self->{+RESULT}->passed ? 'passed' : 'failed');
}

1;
