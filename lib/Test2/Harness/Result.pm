package Test2::Harness::Result;
use strict;
use warnings;

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Util::HashBase qw{
    file name job nested

    is_subtest in_subtest

    total      failed
    start_time stop_time
    exit

    plans
    planning
    plan_errors

    facts
};

sub init {
    my $self = shift;

    croak "'file' is a required attribute"
        unless $self->{+FILE};

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    croak "'name' is a required attribute"
        unless $self->{+NAME};

    $self->{+NESTED} ||= 0;

    # Overall stuff
    $self->{+START_TIME} = time;
    $self->{+TOTAL}      = 0;
    $self->{+FAILED}     = 0;

    # Plan related
    $self->{+PLANS}       = [];
    $self->{+PLANNING}    = [];
    $self->{+PLAN_ERRORS} = [];

    $self->{+FACTS} = [];
}

sub stop {
    my $self = shift;
    my ($exit) = @_;

    $self->{+STOP_TIME} = time;
    $self->{+EXIT}      = $exit;

    $self->_check_plan;
    $self->add_facts(
        Test2::Harness::Fact->new(
            parse_error => $_,
            causes_fail => 1,
            diagnostics => 1,
            nested => $self->nested,
        ),
    ) for @{$self->{+PLAN_ERRORS}};
}

sub passed {
    my $self = shift;
    return unless defined $self->{+STOP_TIME};

    return 0 if $self->{+EXIT};
    return 0 if $self->{+FAILED};
    return 0 if @{$self->{+PLAN_ERRORS}};
    return 1;
}

sub bump_failed { $_[0]->{+FAILED} += $_[1] || 1 }

{
    no warnings 'once';
    *add_fact = \&add_facts;
}
sub add_facts {
    my $self = shift;
    push @{$self->{+FACTS}} => @_;

    for my $f (@_) {
        if ($f->increments_count) {
            $self->{+TOTAL}++;
            push @{$self->{+PLANNING}} => $f;
            push @{$self->{+PLANS}} => $f if $f->sets_plan;
        }
        elsif ($f->sets_plan) {
            push @{$self->{+PLANNING}} => $f;
            push @{$self->{+PLANS}} => $f;
        }

        $self->{+FAILED}++ if $f->causes_fail || $f->terminate;
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
