package Test2::Harness::Result;
use strict;
use warnings;

our $VERSION = '0.000006';

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
    $self->{+START_TIME} ||= time;
    $self->{+TOTAL}      ||= 0;
    $self->{+FAILED}     ||= 0;

    # Plan related
    $self->{+PLANS}       ||= [];
    $self->{+PLANNING}    ||= [];
    $self->{+PLAN_ERRORS} ||= [];

    $self->{+FACTS} ||= [];
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

    return 0 if $self->{+EXIT};
    return 0 if $self->{+FAILED};
    return 0 if @{$self->{+PLAN_ERRORS}};
    return 1;
}

sub bump_failed { $_[0]->{+FAILED} += $_[1] || 1 }

sub add_facts {
    my $self = shift;
    $self->add_fact($_) for @_;
}

sub add_fact {
    my $self = shift;
    my ($f) = @_;

    push @{$self->{+FACTS}} => $f;

    if ($f->is_subtest) {
        $f->set_nested($self->{+NESTED});
        $f->result->update_nest($self->{+NESTED} + 1)
    }

    if ($f->increments_count) {
        $self->{+TOTAL}++;
        push @{$self->{+PLANNING}} => $f;
    }

    if (my $plan = $f->sets_plan) {
        push @{$self->{+PLANNING}} => $f;
        push @{$self->{+PLANS}} => $f
            unless $plan->[1] && $plan->[1] eq 'NO PLAN';
    }

    $self->{+FAILED}++ if $f->causes_fail || $f->terminate;
}

sub update_nest {
    my $self = shift;
    my ($nest) = @_;

    $self->{+NESTED} = $nest;

    for my $f (@{$self->{+FACTS}}) {
        $f->set_nested($nest);
        next unless $f->result;
        $f->result->update_nest($nest + 1);
    }
}

sub _check_numbers {
    my ($self) = @_;

    my $count = 0;
    my %seen;
    my %out_of_order;
    for my $fact (@{$self->{+FACTS}}) {
        next unless $fact->increments_count;
        $count++;

        my $num = $fact->number or next;
        $seen{$num}++;

        next if $count == $num;
        $out_of_order{$num}++;
    }

    my $errors = $self->{+PLAN_ERRORS};

    my @dups = grep { $seen{$_} > 1 } sort { $a <=> $b } keys %seen;
    push @$errors => "Some test numbers were seen more than once: " . join(', ', @dups)
        if @dups;

    my @ooo = sort { $a <=> $b } keys %out_of_order;
    push @$errors => "Some test numbers were seen out of order: " . join(', ', @ooo)
        if @ooo;
}

sub _check_plan {
    my $self = shift;

    my $plans  = $self->{+PLANS};
    my $events = $self->{+PLANNING};
    my $errors = $self->{+PLAN_ERRORS};

    # Already ran and found errors.
    return if @$errors;

    $self->_check_numbers;

    unless (grep {!$_->start} @{$self->{+FACTS}}) {
        push @$errors => 'No events were ever seen!';
        return;
    }

    unless (@$plans) {
        return if $self->is_subtest && !$self->{+TOTAL};
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

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Result - Representation of a complete test or subtest.

=head1 DESCRIPTION

This object is used to represent a complete test or subtest.

=head1 METHODS

=over 4

=item $filename = $r->file

Get the filename of the running test.

=item $name = $r->name

Get the name of the file or subtest.

=item $job_id = $r->job

Get the job id.

=item $int = $r->nested

This will be 0 on the main result for a file. This will be 1 for a top-level
subtest, 2 for nested, etc.

=item $id = $r->is_subtest

Subtest id if this result represents a subtest. The ID is arbitrary and
parser-specific.

=item $id = $r->in_subtest

Subtest id if this result is inside a subtest. The ID is arbitrary and
parser-specific.

=item $int = $r->total

Number of facts that have incremented the test count.

=item $int = $r->failed

Number of failures/errors seen.

=item $ts = $r->start_time

Timestamp from object creation.

=item $ts = $r->stop_time

Timestamp from when the test stopped.

=item $exit = $r->exit

If the test is complete this will have the exit code. This is undefined while
the test is running.

=item $plans_ref = $r->plans

Get a list of all plans encountered. If this has more than 1 plan an error will
be rendered and the test will be considered a failure.

=item $facts_ref = $r->planning

Get a list of all facts that are involved in planning. This includes all plan
facts, and all facts that increment the test count.

=item $errors_ref = $r->plan_errors

Get a list of plan errors (IE Plan and test count do not match).

=item $facts_ref = $r->facts

Get a list of all the facts that were seen.

=item $r->stop($exit)

End the test, and provide the exit code.

=item $bool = $r->passed

Check if the result is a pass.

=item $r->bump_failed

Add to the number of failures.

=item $r->add_facts(@facts)

=item $r->add_fact($fact)

Used to add+process facts.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2016 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
