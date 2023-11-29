package Test2::Harness::Instance::Message;
use strict;
use warnings;

use Carp qw/croak/;
use Scalar::Util qw/blessed/;

use Test2::Harness::Event;

use Test2::Harness::Util::HashBase qw{
    ipc_meta
    connection
    terminate
    run_complete
    +event
};

sub init {
    my $self = shift;
}

sub event {
    my $self = shift;

    my $event = $self->{+EVENT} or return undef;
    return $event if $event && blessed($event) && $event->isa('Test2::Harness::Event');

    $event = decode_json($event) unless ref($event);

    return $self->{+EVENT} = Test2::Harness::Event->new(%$event);
}

sub TO_JSON {
    my $self = shift;
    my $type = blessed($self);

    return { %$self, class => $type };
}

1;
