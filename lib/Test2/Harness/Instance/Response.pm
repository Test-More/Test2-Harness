package Test2::Harness::Instance::Response;
use strict;
use warnings;

use Carp qw/croak/;

use parent 'Test2::Harness::Instance::Message';
use Test2::Harness::Util::HashBase qw{
    <response_id
    <response
    <api
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'response_id' is a required attribute" unless $self->{+RESPONSE_ID};
    croak "'response' is a required attribute" unless exists $self->{+RESPONSE};
    croak "'api' is a required attribute" unless $self->{+API};
}

sub success {
    my $self = shift;
    return $self->{+API}->{success} ? 1 : 0;
}

1;
