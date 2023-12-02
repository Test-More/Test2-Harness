package Test2::Harness::Instance::Request;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;

use parent 'Test2::Harness::Instance::Message';
use Test2::Harness::Util::HashBase qw{
    <request_id
    <api_call
    <args
    <do_not_respond
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    croak "'request_id' is a required attribute" unless $self->{+REQUEST_ID};
    croak "'api_call' is a required attribute"   unless $self->{+API_CALL};
}

1;
