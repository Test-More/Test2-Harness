package Test2::Harness::Event;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util qw/pkg_to_file/;
use Scalar::Util qw/blessed/;
use JSON::MaybeXS qw/JSON/;

use Test2::Util::HashBase qw{
    summary
    fields
    trace
    debug

    stamp

    pid
    tid

    number
    nested
    subevents

    terminate
    global

    diagnostics
    causes_fail
    increments_count
    sets_plan

    in_subtest
    subtest_id

    event_package
    event_file

    parsed_from_line
    parsed_from_handle
};

sub init {
    my $self = shift;
    $self->{+FIELDS} ||= {};
    $self->{+SUMMARY} = "No Summary" unless defined($self->{+SUMMARY});

    $self->{+STAMP} = time;

    # Also bless/convert subevents
    if (my $subs = delete $self->{+SUBEVENTS}) {
        my $class = blessed($self);
        $self->{+SUBEVENTS} = [ map { $class->new(%{$_}) } @$subs ],
    }
}

sub from_line {
    my $class = shift;
    my ($line) = @_;
    return unless $line =~ s/^T2_EVENT:\s//;
    return $class->from_json($line);
}

sub from_json {
    my $class = shift;
    my ($json) = @_;

    my $data = eval { JSON->new->decode($json) };
    my $err = $@;

    return $class->new(%$data) if $data;

    chomp($err);
    return (undef, $err);
}

sub TO_JSON {
    my $self = shift;
    return { %$self };
}

sub to_json {
    my $self = shift;

    my $J = JSON->new;
    $J->indent(0);
    $J->canonical(1);
    $J->convert_blessed(1);

    return $J->encode($self);
}

sub from_event {
    my $class = shift;
    my ($event, %override) = @_;

    my $epkg  = blessed($event);
    my $efile = $INC{pkg_to_file($epkg)};

    my %attrs = (
        EVENT_PACKAGE() => $epkg,
        EVENT_FILE()    => $efile,

        SUMMARY()          => $event->summary          || "Unknown",
        CAUSES_FAIL()      => $event->causes_fail      || 0,
        INCREMENTS_COUNT() => $event->increments_count || 0,
        TERMINATE()        => $event->terminate        || 0,
        GLOBAL()           => $event->global           || 0,
        NESTED()           => $event->nested           || 0,
        DIAGNOSTICS()      => $event->diagnostics      || 0,
        IN_SUBTEST()       => $event->in_subtest       || undef,
    );

    $attrs{+FIELDS} = {map { ref($event->{$_}) ? () : ($_ => $event->{$_}) } keys %$event};

    if(my @plan = $event->sets_plan) {
        $attrs{+SETS_PLAN} = \@plan;
    }

    $attrs{+SUBEVENTS} = [map { $class->from_event($_) } @{$event->subevents}]
        if $event->can('subevents');

    $attrs{+SUBTEST_ID} = $event->subtest_id
        if $event->can('subtest_id');

    if (my $trace = $event->trace) {
        $attrs{+DEBUG} = $trace->debug || "";
        $attrs{+TRACE} = $trace->frame;
        $attrs{+PID}   = $trace->pid;
        $attrs{+TID}   = $trace->tid;
    }

    return $class->new(%attrs, %override);
}

sub set_field {
    my $self = shift;
    my ($f, $v) = @_;
    $self->{+FIELDS}->{$f} = $v;
}

sub get_field {
    my $self = shift;
    my ($f) = @_;
    $self->{+FIELDS}->{$f};
}

sub get_fields {
    my $self = shift;
    @{$self->{+FIELDS}}{@_};
}

sub list_fields {
    my $self = shift;
    sort keys %{$self->{+FIELDS}};
}

1;
