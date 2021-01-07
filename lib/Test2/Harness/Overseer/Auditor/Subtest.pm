package Test2::Harness::Overseer::Auditor::Subtest;
use strict;
use warnings;

our $VERSION = '1.000043';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;

use Test2::Harness::Util qw/hub_truth/;

use Test2::Harness::Util::HashBase qw{
    <assertion_count
    <exit
    <plan
    <numbers
    <halt

    +errors
    +failures
    +sub_failures
    +plans
    +info
    +sub_info
};

sub init {
    my $self = shift;

    $self->{+FAILURES}        = 0;
    $self->{+ERRORS}          = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS} = {};
}

sub pass { !$_[0]->fail }
sub fail { !!$_[0]->fail_error_facet_list }

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

sub process {
    my $self = shift;
    my ($event, $f, $hf) = @_;

    $f  //= $event->facet_data;
    $hf //= hub_truth($f);

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    if ($f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
        $self->{+FAILURES}++;
    }

    if ($f->{control} || $f->{errors}) {
        my $err ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+ERRORS}++ if $err;
        $self->{+HALT} = $f->{control}->{details} || '1' if $f->{control} && $f->{control}->{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1');
    }

    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    if ($f->{harness_job_exit}) {
        $self->{+EXIT} = $f->{harness_job_exit};
    }

    return;
}

sub subtest_fail_error_facet_list {
    my $self = shift;

    return @{$self->{+SUB_INFO}} if $self->{+SUB_INFO};

    my @out;

    my $plan = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            if (!$numbers->{$i}) {
                push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Assertion number $i was never seen"};
            }
            elsif ($numbers->{$i} > 1) {
                push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Assertion number $i was seen more than once"};
            }
        }
    }

    if (!$self->{+PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "No plan was declared"};
        }
        else {
            push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "No plan was declared, and no assertions were made."};
        }
    }
    elsif ($self->{+PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Too many plans were declared (Count: $self->{+PLANS})"};
    }

    push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Planned for $plan assertions, but saw $self->{+ASSERTION_COUNT}"}
        if $plan && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Subtest failures were encountered (Count: $self->{+SUB_FAILURES})"}
        if $self->{+SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list {
    my $self = shift;

    return @{$self->{+INFO}} if $self->{+INFO};

    my @out;

    if (my $e = $self->{+EXIT}) {
        if ($e->{exit} == -1) {
            push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "The harness could not get the exit code! (Code: $e->{exit})"};
        }
        else {
            if ($e->{code}) {
                push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Test script returned error (Err: $e->{code})"};
            }
            if ($e->{signal}) {
                push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Test script returned error (Signal: $e->{signal})"};
            }
        }
    }

    push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Errors were encountered (Count: $self->{+ERRORS})"}
        if $self->{+ERRORS};

    push @out => {tag => 'REASON', fail => 1, from_audit => 1, details => "Assertion failures were encountered (Count: $self->{+FAILURES})"}
        if $self->{+FAILURES};

    push @out => $self->subtest_fail_error_facet_list();

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Overseer::Auditor::Subtest - Class to monitor events for a
single subtest and render a pass/fail verdict.

=head1 DESCRIPTION

This module represents a per-subtest state tracker. This module sees every
event and manages the state produced. In the end this tracker determines if a
test job passed or failed, and why.

=head1 SYNOPSIS

    use Test2::Harness::Overseer::Auditor::Subtest;

    my $subtest = Test2::Harness::Overseer::Auditor::Subtest->new();

    for my $event (@events) {
        $subtest->process($event);
    }

    print "Pass!" if $subtest->pass;
    print "Fail!" if $subtest->fail;

=head1 METHODS

=over 4

=item $int = $subtest->assertion_count()

Number of assertions that have been seen.

=item $exit = $subtest->exit()

If an event with a C<harness_job_exit> facet has been seen, this will return
the facet.

=item $bool = $subtest->fail()

Returns true if the job has failed/is failing.

=item @error_facets = $subtest->fail_error_facet_list

Used internally to get a list of 'error' facets to inject into the
harness_job_exit event.

=item $string = $subtest->halt

If the test was halted (bail-out) this will contain the human readible reason.

=item $bool = $subtest->has_exit

Check if the exit value is known.

=item $bool = $subtest->has_plan

Check if a plan has been seen.

=item $hash = $subtest->numbers

This is an internal state tracking what test numbers have been seen. This is
really only applicable in tests that produced TAP.

=item $bool = $subtest->pass

Check if the test job is passing.

=item $plan_facet = $subtest->plan()

If the plan facet has been seen this will return it.

=item $subtest->process($event);

Modify the state based on the provided event.

=item $subtest->subtest_fail_error_facet_list

Used internally to get a list of 'error' facets to inject into the
harness_job_exit event.

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

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
