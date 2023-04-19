package Test2::Harness::Collector::IOParser;
use strict;
use warnings;

use Carp qw/confess/;
use Time::HiRes qw/time/;
use Test2::Harness::Util::UUID qw/gen_uuid/;

our $VERSION = '2.000000';

use Test2::Harness::Util::HashBase qw{
    -run_id
    -job_id
    -job_try
    -name
    -type
};

sub parse_io {
    my $self = shift;
    my ($io) = @_;

    my $stream = $io->{stream} or confess "No Stream!";

    my $event = $self->get_event($io);

    $self->parse_process_action($io, $event) if $stream eq 'process';
    $self->parse_stream_line($io, $event)    if defined $io->{line};

    $self->normalize_event($io, $event);

    return ($event);
}

sub normalize_event {
    my $self = shift;
    my ($io, $event) = @_;

    my $stamp    = $event->{stamp}    // $event->{facet_data}->{harness}->{stamp}    // $io->{stamp}    // time;
    my $event_id = $event->{event_id} // $event->{facet_data}->{harness}->{event_id} // $io->{event_id} // gen_uuid();

    my %fields = (
        stamp    => $stamp,
        event_id => $event_id,
        run_id   => $self->{+RUN_ID},
        job_id   => $self->{+JOB_ID},
        job_try  => $self->{+JOB_TRY},
    );

    for my $field (keys %fields) {
        if (defined $event->{$field}) {
            die "'$field' mismatch, internal inconsistency." unless $event->{$field} eq $fields{$field};
        }
        else {
            $event->{$field} = $fields{$field};
        }

        if (defined $event->{facet_data}->{harness}->{$field}) {
            die "'$field' mismatch, internal inconsistency." unless $event->{facet_data}->{harness}->{$field} eq $fields{$field};
        }
        else {
            $event->{facet_data}->{harness}->{$field} = $fields{$field};
        }
    }
}

sub get_event {
    my $self = shift;
    my ($io) = @_;

    my $event = $io->{event} // $io->{data} // {
        stamp      => $io->{stamp}    // time,
        event_id   => $io->{event_id} // gen_uuid(),
        facet_data => {},
    };

    delete $io->{event};
    delete $io->{data};

    return $event;
}

sub parse_stream_line {
    my $self = shift;
    my ($io, $event) = @_;

    my $stream   = $io->{stream};
    my $ucstream = uc($stream);

    my $text = delete $io->{line};

    push @{$event->{facet_data}->{info}} => {
        details => $text,
        tag     => $ucstream,
        debug   => ($ucstream eq 'STDERR' ? 1 : 0),
    };
}

sub parse_process_action {
    my $self = shift;
    my ($io, $event) = @_;

    my $action = $io->{action} or return;
    my $data   = $io->{$action};
    my $name   = $self->{+NAME};
    my $type   = $self->{+TYPE};

    if ($action eq 'launch') {
        $event->{facet_data}->{launch} = $data;
        push @{$event->{facet_data}->{info}} => {
            tag     => 'PROCESS',
            details => "Launched '$type' process `$name`",
        };
    }

    if ($action eq 'exit') {
        $event->{facet_data}->{exit} = $data;
        push @{$event->{facet_data}->{info}} => {
            tag     => 'PROCESS',
            details => "'$type' process `$name` exited with status $data->{exit}->{all}",
            debug   => $data->{exit}->{all} ? 1 : 0,
        };
    }
}

1;
