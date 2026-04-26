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
    <compressed_form
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

# Drop the cached on-wire compressed bytes (and the cached JSON
# encoding that pairs with them). Auditors and other consumers that
# mutate the event must call this so a downstream zstd-aware logger
# does not write stale compressed bytes that no longer match the
# (mutated) event body.
sub clear_compressed_form {
    my $self = shift;
    delete $self->{+COMPRESSED_FORM};
    delete $self->{+JSON};
    return;
}

sub TO_JSON {
    my $out = {%{$_[0]}};

    delete $out->{+JSON};
    delete $out->{+COMPRESSED_FORM};

    $out->{+FACET_DATA} = {%{$out->{+FACET_DATA}}} if $out->{+FACET_DATA};

    return $out;
}

1;
