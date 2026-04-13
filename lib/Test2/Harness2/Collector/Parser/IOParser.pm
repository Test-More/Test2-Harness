package Test2::Harness2::Collector::Parser::IOParser;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Event;

use Test2::Harness2::Util::HashBase qw{
    <run_id
    <job_id
    <job_try
    <name
    <type
};

sub parse_io {
    my $self = shift;
    my (%params) = @_;

    my $stream = $params{stream} or croak "No 'stream' provided";
    my $line   = $params{line};

    return unless defined $line;

    my $event = $self->get_event(%params);

    $self->parse_stream_line(\%params, $event) if defined $params{line};

    $self->normalize_event(\%params, $event);

    return $event;
}

sub normalize_event {
    my $self = shift;
    my ($io, $event) = @_;

    my $stamp    = $event->{stamp}    // $io->{stamp}    // time;
    my $event_id = $event->{event_id} // $io->{event_id} // gen_uuid();

    $event->{stamp}    = $stamp;
    $event->{event_id} = $event_id;

    $event->{facet_data}{harness}{stamp}    = $stamp;
    $event->{facet_data}{harness}{event_id} = $event_id;

    if (defined $self->{+RUN_ID}) {
        $event->{facet_data}{harness}{run_id} //= $self->{+RUN_ID};
    }
    if (defined $self->{+JOB_ID}) {
        $event->{facet_data}{harness}{job_id} //= $self->{+JOB_ID};
    }
    if (defined $self->{+JOB_TRY}) {
        $event->{facet_data}{harness}{job_try} //= $self->{+JOB_TRY};
    }
}

sub get_event {
    my $self = shift;
    my (%params) = @_;

    return Test2::Harness2::Event->new(
        stamp      => $params{stamp}    // time,
        event_id   => $params{event_id} // gen_uuid(),
        facet_data => {},
    );
}

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream   = $io->{stream};
    my $ucstream = uc($stream);

    my $text = $io->{line};
    my $tag  = $ucstream;

    $event->{facet_data}{from_stream} = {source => $ucstream, details => $text};

    push @{$event->{facet_data}{info}} => {
        details => $text,
        tag     => $tag,
        debug   => ($ucstream eq 'STDERR' ? 1 : 0),
    };
}

1;
