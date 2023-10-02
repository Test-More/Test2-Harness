package Test2::Harness::Auditor::Watcher;
use strict;
use warnings;

our $VERSION = '1.000155';

use Carp qw/croak confess/;
use Scalar::Util qw/blessed/;
use List::Util qw/first max/;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util qw/hub_truth parse_exit/;

use Test2::Harness::Auditor::TimeTracker;

use Test2::Harness::Util::HashBase qw{
    -job
    -try

    -assertion_count
    -exit
    -plan
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -_info
    -_sub_info
    -_subtest_id
    -nested
    -subtests
    -numbers
    -times
    -halt
    -failed_subtest_tree
};

sub init {
    my $self = shift;

    croak "'job' is a required attribute"
        unless $self->{+JOB};

    croak "'try' is a required attribute"
        unless defined $self->{+TRY};

    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS} = {};
    $self->{+TIMES} = Test2::Harness::Auditor::TimeTracker->new();

    $self->{+NESTED} = 0 unless defined $self->{+NESTED};
}

sub pass { !$_[0]->fail }
sub file { $_[0]->{+JOB}->{file} }
sub fail { !!$_[0]->fail_error_facet_list }

sub has_exit { defined $_[0]->{+EXIT} }
sub has_plan { defined $_[0]->{+PLAN} }

sub process {
    my $self = shift;
    my ($event) = @_;

    my $f  = $event->{facet_data};
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    $self->times->process($event, $f, $self->{+ASSERTION_COUNT}) unless $nested;

    return if $hf->{buffered};

    my $is_ours = $nested == $self->{+NESTED};

    return unless $is_ours || $f->{from_tap};

    # Add parent if we start a buffered subtest
    if ($f->{harness} && $f->{harness}->{subtest_start}) {
        my $st = $self->{+SUBTESTS}->{$nested + 1} ||= {};
        $st->{event} = $event;
        $f->{harness_watcher}->{no_render} = 1;
        return;
    }

    my @out;

    # Not actually a subtest end, someone printed to STDOUT
    if ($f->{from_tap} && $f->{harness}->{subtest_end} && !($self->{+SUBTESTS} && keys %{$self->{+SUBTESTS}})) {
        # Alter $f so that this incorrect event is not sent to the renderer.
        $f->{harness_watcher}->{no_render} = 1;

        # Make a new $f and $event for the rest of the processing.
        $f = {
            %{$f},
            harness_watcher => {added_by_watcher => 1},
            parent          => undef,
            trace           => undef,
            harness         => {
                %{$f->{harness} || {}},
                subtest_end => undef,
            },
            info => [
                @{$f->{info} || []},
                {
                    details      => $f->{from_tap}->{details},
                    tag          => $f->{from_tap}->{source} || 'STDOUT',
                    from_harness => 1,
                }
            ],
        };

        $event = Test2::Harness::Event->new(stamp => time, job_try => $self->{+TRY}, facet_data => $f);
    }

    push @out => $event;

    # Close any deeper subtests
    if (my $sts = $self->{+SUBTESTS}) {
        my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;

        for my $n (@close) {
            my $st = delete $sts->{$n};
            my $se = $st->{event} || $event;

            my $fd = $se->{facet_data};
            delete $fd->{harness_watcher}->{no_render};
            $fd->{parent}->{hid} ||= $n;
            $fd->{parent}->{children} ||= $st->{children};
            $fd->{harness}->{closed_by}     = $event;
            $fd->{harness}->{closed_by_eid} = $event->{event_id};

            my $pn = $n - 1;

            if ($st->{event}) {
                if ($pn > $self->{+NESTED}) {
                    push @{$sts->{$pn}->{children}} => $fd;
                }
                elsif ($pn == $self->{+NESTED}) {
                    $self->subtest_process($fd, $se);
                    push @out => $se;
                }
            }
            else {
                push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
            }
        }
    }

    unless ($is_ours) {
        my $st = $self->{+SUBTESTS}->{$nested} ||= {};
        my $fd = {%$f};
        push @{$st->{children}} => $fd;
        return @out;
    }

    $self->subtest_process($f, $event);
    return @out;
}

sub subtest_process {
    my $self = shift;
    my ($f, $event) = @_;

    my $closer = delete $f->{harness}->{closed_by};
    $event ||= Test2::Harness::Event->new(facet_data => $f, job_try => $self->{+TRY});

    $self->{+NUMBERS}->{$f->{assert}->{number}}++
        if $f->{assert} && $f->{assert}->{number};

    if ($f->{parent} && $f->{assert}) {
        my $name = $f->{assert}->{details} // "unnamed subtest ($f->{trace}->{frame}->[1] line $f->{trace}->{frame}->[2])";

        my $subwatcher = blessed($self)->new(nested => $self->{+NESTED} + 1, job => $self->{+JOB}, try => $self->{+TRY});

        my $id = 1;
        for my $sf (@{$f->{parent}->{children}}) {
            $sf->{harness}->{job_id}   ||= $f->{harness}->{job_id};
            $sf->{harness}->{run_id}   ||= $f->{harness}->{run_id};
            $sf->{harness}->{event_id} ||= $sf->{about}->{uuid} ||= gen_uuid();
            $subwatcher->subtest_process($sf);
        }

        my @errors = $subwatcher->subtest_fail_error_facet_list();

        if ($f->{harness}->{subtest_start}) {
            push @{$f->{errors}} => {tag => 'REASON', fail => 1, from_harness => 1, details => "Buffered subtest ended abruptly (missing closing brace event)"}
                unless $closer && $closer->{facet_data}->{harness}->{subtest_end};
        }

        my $fail = 0;
        if (@errors) {
            push @{$f->{errors}} => @errors;
            $fail = 1;
        }
        else {
            $fail ||= $f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
            $fail ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
            $fail ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        }

        if ($fail) {
            $self->{+_SUB_FAILURES}++;

            # Populate the tree up to this subtest
            my $tree = $self->{+FAILED_SUBTEST_TREE} //= [];
            push @$tree => [$name, $subwatcher->{+FAILED_SUBTEST_TREE} // []];
        }
    }

    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    if ($f->{assert} && !$f->{assert}->{pass} && !($f->{amnesty} && @{$f->{amnesty}})) {
        $self->{+_FAILURES}++;
    }

    if ($f->{control} || $f->{errors}) {
        my $err ||= $f->{control} && ($f->{control}->{halt} || $f->{control}->{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $err;
        $self->{+HALT} = $f->{control}->{details} || '1' if $f->{control} && $f->{control}->{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1');
    }

    if ($f->{plan} && !$f->{plan}->{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    if ($f->{harness_job_exit}) {
        $self->{+EXIT} = $f->{harness_job_exit}->{exit};

        my $file = $self->file();

        my $end = $f->{harness_job_end} = {
            file     => $file,
            rel_file => File::Spec->abs2rel($file),
            abs_file => File::Spec->rel2abs($file),
            retry    => $f->{harness_job_exit}->{retry},
            fail     => $self->fail(),
            stamp    => $f->{harness_job_exit}->{stamp},
        };

        my $plan = $self->plan;
        $end->{skip} = $plan->{details} || "No reason given" if $plan && !$plan->{count};

        my $times = $self->times;
        if ($times && $times->useful) {
            $end->{times} = $times->data_dump;
            push @{$f->{harness_job_fields}} => $times->job_fields;
            push @{$f->{info}} => {tag => 'TIME', details => $times->summary, table => $times->table};
        }

        push @{$f->{errors}} => $self->fail_error_facet_list;
    }

    return;
}

sub subtest_fail_error_facet_list {
    my $self = shift;

    return @{$self->{+_SUB_INFO}} if $self->{+_SUB_INFO};

    my @out;

    my $plan = $self->{+PLAN} ? $self->{+PLAN}->{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            if (!$numbers->{$i}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was never seen"};
            }
            elsif ($numbers->{$i} > 1) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion number $i was seen more than once"};
            }
        }
    }

    if (!$self->{+_PLANS}) {
        if ($count) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared"};
        }
        else {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "No plan was declared, and no assertions were made."};
        }
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Too many plans were declared (Count: $self->{+_PLANS})"};
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Planned for $plan assertions, but saw $self->{+ASSERTION_COUNT}"}
        if $plan && $count != $plan;

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})"}
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list {
    my $self = shift;

    return @{$self->{+_INFO}} if $self->{+_INFO};

    my @out;

    my $incomplete_subtests = values %{$self->{+SUBTESTS}};
    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "One or more incomplete subtests (Count: $incomplete_subtests)"}
        if $incomplete_subtests;

    if (my $wstat = $self->{+EXIT}) {
        if ($wstat == -1) {
            push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "The harness could not get the exit code! (Code: $wstat)"};
        }
        else {
            my $e = parse_exit($wstat);
            if ($e->{err}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Err: $e->{err})"};
            }
            if ($e->{sig}) {
                push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Test script returned error (Signal: $e->{sig})"};
            }
        }
    }

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Errors were encountered (Count: $self->{+_ERRORS})"}
        if $self->{+_ERRORS};

    push @out => {tag => 'REASON', fail => 1, from_harness => 1, details => "Assertion failures were encountered (Count: $self->{+_FAILURES})"}
        if $self->{+_FAILURES};

    push @out => $self->subtest_fail_error_facet_list();

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Auditor::Watcher - Class to monitor events for a single job and
pass judgement on the result.

=head1 DESCRIPTION

This module represents a per-job state tracker. This module sees every event
and manages the state produced. In the end this tracker determines if a test
job passed or failed, and why.

=head1 SYNOPSIS

    use Test2::Harness::Auditor::Watcher;

    my $watcher = Test2::Harness::Auditor::Watcher->new();

    for my $event (@events) {
        $watcher->process($event);
    }

    print "Pass!" if $watcher->pass;
    print "Fail!" if $watcher->fail;

=head1 METHODS

=over 4

=item $int = $watcher->assertion_count()

Number of assertions that have been seen.

=item $exit = $watcher->exit()

If the job has exited this will return the exit value (integer, 0 or greater).
If the job has not exited yet (or at least if the watcher has not seen the exit
event yet) this will return undef.

=item $bool = $watcher->fail()

Returns true if the job has failed/is failing.

=item @error_facets = $watcher->fail_error_facet_list

Used internally to get a list of 'error' facets to inject into the
harness_job_exit event.

=item $file = $watcher->file

If the test file is known this will return it (string). This will return undef
if the file is not yet known.

=item $string = $watcher->halt

If the test was halted (bail-out) this will contain the human readible reason.

=item $bool = $watcher->has_exit

Check if the exit value is known.

=item $bool = $watcher->has_plan

Check if a plan has been seen.

=item $job = $watcher->job

If the job is known this will return the detailed structure of the job.

=item $int = $watcher->nested

If this watcher represents a subtest this will be an integer greater than 0,
the top-level test is 0.

=item $hash = $watcher->numbers

This is an internal state tracking what test numbers have been seen. This is
really only applicable in tests that produced TAP.

=item $bool = $watcher->pass

Check if the test job is passing.

=item $plan_facet = $watcher->plan()

If the plan facet has been seen this will return it.

=item $watcher->process($event);

Modify the state based on the provided event.

=item $watcher->subtest_fail_error_facet_list

Used internally to get a list of 'error' facets to inject into the
harness_job_exit event.

=item $times = $watcher->times()

Retuns the L<Test2::Harness::Auditor::TimeTracker> instance.

=item $int = $watcher->try()

Sometimes a job is run more than once, in those cases this will be an integer
greater than 0 representing the try. 0 is used for the first try.

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
