package Test2::Harness::Fact;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util qw/pkg_to_file/;
use Scalar::Util qw/blessed/;
use JSON::MaybeXS qw/JSON/;

use Test2::Util::HashBase qw{
    stamp
    _summary
    nested

    diagnostics
    causes_fail
    increments_count
    sets_plan
    in_subtest
    is_subtest
    terminate

    start
    event
    result
    parse_error
    output

    parsed_from_string
    parsed_from_handle
};

sub init {
    my $self = shift;

    $self->{+STAMP} = time;
    $self->{+_SUMMARY} = delete $self->{summary} if $self->{summary};
    $self->{+NESTED} ||= 0;
}

sub summary {
    my $self = shift;
    return $self->{+_SUMMARY}     if defined $self->{+_SUMMARY};
    return $self->{+START}        if defined $self->{+START};
    return $self->{+PARSE_ERROR}  if defined $self->{+PARSE_ERROR};
    return $self->{+OUTPUT}       if defined $self->{+OUTPUT};
    return $self->{+RESULT}->name if defined $self->{+RESULT};
    return "no summary";
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

sub from_string {
    my $class = shift;
    my ($string, %override) = @_;
    return unless $string =~ s/^T2_EVENT:\s//;
    return $class->from_json($string, parsed_from_String => $string, %override);
}

sub from_json {
    my $class = shift;
    my ($json, %override) = @_;

    my $data = eval { JSON->new->decode($json) };
    my $err = $@;

    return $class->new(%$data, %override) if $data;

    chomp($err);
    return $class->new(
        summary     => $err,
        parse_error => $err,
        causes_fail => 1,
        diagnostics => 1,
    );
}

sub from_event {
    my $class = shift;
    my ($event, %override) = @_;

    my $epkg  = blessed($event);
    my $efile = $INC{pkg_to_file($epkg)};

    my @plan = $event->sets_plan;

    my $event_data = {
        '__PACKAGE__' => $epkg,
        '__FILE__'    => $efile,

        map { ref($event->{$_}) ? () : ($_ => $event->{$_}) } keys %$event,
    };

    if (my $trace = $event->trace) {
        $event_data->{trace} = { %$trace };
    }

    my %attrs = (
        EVENT() => $event_data,

        _SUMMARY()         => $event->summary          || "[no summary]",
        CAUSES_FAIL()      => $event->causes_fail      || 0,
        INCREMENTS_COUNT() => $event->increments_count || 0,
        NESTED()           => $event->nested           || 0,
        DIAGNOSTICS()      => $event->diagnostics      || 0,
        IN_SUBTEST()       => $event->in_subtest       || undef,
        TERMINATE()        => $event->terminate        || undef,

        SETS_PLAN() => @plan ? \@plan : undef,
        IS_SUBTEST() => $event->can('subtest_id') ? $event->subtest_id || undef : undef,
    );

    return $class->new(%attrs, %override);
}

sub from_result {
    my $class = shift;
    my ($result, %override) = @_;

    my %attrs = (
        RESULT() => $result,

        NESTED()      => $result->nested     || 0,
        IN_SUBTEST()  => $result->in_subtest || undef,
        IS_SUBTEST()  => $result->is_subtest || undef,

        CAUSES_FAIL() => $result->passed ? 0 : 1,
    );

    return $class->new(%attrs, %override);
}

1;
