package Test2::Harness2::Event;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Object::HashBase qw{
    <facet_data
    <stream_id
    <event_id
    <stamp
    +json
};

sub init {
    my $self = shift;

    $self->{+FACET_DATA} //= {};
    $self->{+STAMP}      //= time;

    confess "'event_id' is a required attribute"
        unless defined $self->{+EVENT_ID};
}

sub as_json { $_[0]->{+JSON} //= encode_json($_[0]) }

sub TO_JSON {
    my $out = {%{$_[0]}};

    delete $out->{+JSON};

    $out->{+FACET_DATA} = {%{$out->{+FACET_DATA}}} if $out->{+FACET_DATA};

    return $out;
}

1;
