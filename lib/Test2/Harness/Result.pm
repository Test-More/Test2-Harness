package Test2::Harness::Result;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Util::HashBase qw{
    file job nested

    total      failed
    start_time stop_time
    exit

    fail_events
    fail_subtests

    plans
    planning
    plan_errors

    events
    out_lines err_lines
    subtests
    parse_errors
    muxed
};

our @EXPORT_OK = qw{
    EVENTS
    OUT_LINES
    ERR_LINES
    SUBTESTS
    PARSE_ERRORS
};
use base 'Exporter';

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    $self->{+NESTED} ||= 0;

    # Overall stuff
    $self->{+START_TIME} = time;
    $self->{+TOTAL}      = 0;
    $self->{+FAILED}     = 0;

    # Plan related
    $self->{+PLANS}       = [];
    $self->{+PLANNING}    = [];
    $self->{+PLAN_ERRORS} = [];

    # Just the failures
    $self->{+FAIL_EVENTS}   = [];
    $self->{+FAIL_SUBTESTS} = [];

    # Muxed things
    $self->{+EVENTS}       = [];
    $self->{+OUT_LINES}    = [];
    $self->{+ERR_LINES}    = [];
    $self->{+SUBTESTS}     = [];
    $self->{+PARSE_ERRORS} = [];
    $self->{+MUXED}        = [];
}

sub duration {
    my $self = shift;
    return $self->{+STOP_TIME} - $self->{+START_TIME};
}

sub stop {
    my $self = shift;
    my ($exit) = @_;

    $self->{+STOP_TIME} = time;
    $self->{+EXIT}      = $exit;

    $self->_check_plan;
}

sub passed {
    my $self = shift;
    return unless defined $self->{+STOP_TIME};

    return 0 if $self->failed;
    return 0 if @{$self->{+PLAN_ERRORS}};
    return 1;
}

sub bump_failed { $_[0]->{+FAILED} += $_[1] || 1 }

sub add {
    my $self = shift;
    my ($type, @stuff) = @_;

    my $meth = "add_$type";
    croak ref($self) . " does not know how to add items to '$type'"
        unless $self->can($meth);

    $self->$meth(@stuff);
}

BEGIN {
    my @MUX = (
        OUT_LINES(),
        ERR_LINES(),
        PARSE_ERRORS(),
    );
    
    for my $mux (@MUX) {
        my $code = sub {
            my $self = shift;
            push @{$self->{$mux}} => @_;
            push @{$self->{+MUXED}} => [$mux => @_];
        };
        no strict 'refs';
        *{"add_$mux"} = $code;
    }
}

sub add_subtests {
    my $self = shift;
    push @{$self->{+SUBTESTS}} => @_;
    push @{$self->{+MUXED}}    => @_;

    for my $st (@_) {
        next if $st->passed;
        push @{$self->{+FAIL_SUBTESTS}} => $st;
        $self->{+FAILED}++;
    }
}

sub add_events {
    my $self = shift;
    push @{$self->{+EVENTS}} => @_;
    push @{$self->{+MUXED}}  => @_;

    for my $e (@_) {
        if ($e->increments_count) {
            $self->{+TOTAL}++;
            push @{$self->{+PLANNING}} => $e;
            push @{$self->{+PLANS}} => $e if $e->sets_plan;
        }
        elsif ($e->sets_plan) {
            push @{$self->{+PLANNING}} => $e;
            push @{$self->{+PLANS}} => $e;
        }

        if ($e->causes_fail || $e->terminate) {
            push @{$self->{+FAIL_EVENTS}} => $e;
            $self->{+FAILED}++;
        }
    }
}

sub _check_plan {
    my $self = shift;

    my $plans  = $self->{+PLANS};
    my $events = $self->{+PLANNING};
    my $errors = $self->{+PLAN_ERRORS};

    # Already ran and found errors.
    return if @$errors;

    unless (@$plans) {
        push @$errors => 'No plan was ever set.';
        return;
    }

    push @$errors => 'Multiple plans were set.'
        if @$plans > 1;

    my ($plan) = @$plans;

    push @$errors => 'Plan must come before or after all testing, not in the middle.'
        unless $plan == $events->[0] || $plan == $events->[-1];

    my ($max) = @{$plan->sets_plan};

    return if $max == $self->{+TOTAL};
    push @$errors => "Planned to run $max test(s) but ran $self->{+TOTAL}."
}

1;

__END__
