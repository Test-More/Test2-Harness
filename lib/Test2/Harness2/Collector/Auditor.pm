package Test2::Harness2::Collector::Auditor;
use v5.38;

our $VERSION = '2.000000';

use Scalar::Util qw/blessed/;
use List::Util qw/first max/;
use Time::HiRes qw/time/;

use Test2::Harness2::Util qw/hub_truth/;
use Test2::Harness2::Util::IPC qw/parse_exit/;
use Test2::Harness2::Event;
use Test2::Harness2::Collector::Auditor::TimeTracker;

use Object::HashBase qw{
    -assertion_count
    -exit
    -plan
    +fail
    -_errors
    -_failures
    -_sub_failures
    -_plans
    -nested
    -subtests
    -numbers
    -halt
    -failed_subtest_tree
    -passing_subtests
    -failing_subtests
    -top_level_subtests
    -started
    -times
    +_state_failing
    +_state_diagnosing
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Processor';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor - Collector processor that audits a
test job's event stream and decides pass/fail.

=head1 DESCRIPTION

The auditor sits in the processor slot of the collector pipeline. It consumes
one L<Test2::Harness2::Event> at a time via L</process_event> and:

=over 4

=item *

passes events through (transforming subtest streams into buffered parent
events, recovering malformed TAP, and synthesizing subtest-start
announcements);

=item *

tracks the running test's verdict -- assertions, assertion numbering, plans,
nested subtests (recursively, via a fresh sub-auditor per subtest), errors,
bail-outs, and the child's exit status;

=item *

emits B<state-transition events> (C<harness_state_transition> facet, state
C<starting> / C<failing> / C<diagnosing> / C<completed>) as additional
events; and

=item *

emits a B<final-state event> (C<harness_final_state> facet) once it sees the
synthetic process-exit event.

=back

A test-aware recorder routes the transition and final-state events into their
own files; a plain recorder records them like any other event.

Pass/fail is the verdict of L</fail_error_facet_list>: a test fails if it
declared no plan, declared too many, planned a different count than it ran,
skipped or repeated an assertion number, left a subtest incomplete, exited
non-zero, or registered an error / assertion / subtest failure. The reasons
are attached as error facets to the process-exit event.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Auditor;

    my $auditor = Test2::Harness2::Collector::Auditor->new;
    my @out     = $auditor->process_event($event);   # 1+ events
    my $verdict = $auditor->final_state;             # after the run

=head1 ATTRIBUTES

=over 4

=item nested

Subtest nesting depth this auditor represents. C<0> (the default) is the
top-level test; nested sub-auditors are spawned automatically. All other
state is internal and reached through the methods below.

=back

=cut

sub init ($self) {
    $self->{+_FAILURES}       = 0;
    $self->{+_ERRORS}         = 0;
    $self->{+_SUB_FAILURES}   = 0;
    $self->{+_PLANS}          = 0;
    $self->{+ASSERTION_COUNT} = 0;

    $self->{+NUMBERS}            = {};
    $self->{+SUBTESTS}           = {};
    $self->{+PASSING_SUBTESTS}   = [];
    $self->{+FAILING_SUBTESTS}   = [];
    $self->{+TOP_LEVEL_SUBTESTS} = [];

    $self->{+NESTED} //= 0;
    $self->{+STARTED}           = 0;
    $self->{+_STATE_FAILING}    = 0;
    $self->{+_STATE_DIAGNOSING} = 0;

    # Only the top-level auditor tracks wall-clock phase timing; sub-auditors
    # audit buffered children that carry no launch/exit stamps.
    $self->{+TIMES} = Test2::Harness2::Collector::Auditor::TimeTracker->new
        if $self->{+NESTED} == 0;

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item process_event

=item @events = $auditor->process_event($event)

Audit C<$event> and return the events to record. The first call is preceded
by a C<starting> transition; an event that newly trips the failing /
diagnosing state is followed by the matching transition; and the
process-exit event is followed by a C<completed> transition and the
final-state event.

=item $bool = $auditor->pass

=item $bool = $auditor->fail

The verdict. C<fail> is true when L</fail_error_facet_list> returns any
reason; C<pass> is its inverse.

=item $n = $auditor->fail_count

=item $n = $auditor->pass_count

Failure and passing-assertion counts.

=item $bool = $auditor->has_exit

=item $bool = $auditor->has_plan

Whether an exit / plan has been seen.

=item $state = $auditor->final_state

Hashref verdict snapshot: C<pass>, C<fail_count>, C<pass_count>,
C<assertion_count>, C<exit>, and C<subtests> (the top-level subtest summary),
plus C<plan>, C<halt>, and C<times> (startup / events / cleanup / total phase
durations) when available.

=item fail_error_facet_list

=item @facets = $auditor->fail_error_facet_list

=item @facets = $auditor->subtest_fail_error_facet_list

Error-facet lists describing every reason the run (or a single subtest's
contents) is failing. Attached to the process-exit event.

=back

=cut

sub process_event ($self, $event) {
    my @out;

    unless ($self->{+STARTED}) {
        $self->{+STARTED} = 1;
        push @out => $self->_transition('starting');
    }

    my $f = $event->facet_data;

    if (!$self->{+_STATE_FAILING} && $self->_event_is_failing($f)) {
        $self->{+_STATE_FAILING} = 1;
        push @out => $self->_transition('failing');
    }

    if (!$self->{+_STATE_DIAGNOSING} && $self->_event_is_diagnostic($f)) {
        $self->{+_STATE_DIAGNOSING} = 1;
        push @out => $self->_transition('diagnosing');
    }

    my $is_exit = $f->{harness_process_exit} ? 1 : 0;

    for my $se ($self->_audit($event)) {
        next unless ref $se;
        my $sf = $se->facet_data;
        delete $sf->{harness}{closed_by} if $sf->{harness};
        push @out => $se;
    }

    $self->{+TIMES}->process($event, $self->{+ASSERTION_COUNT}) if $self->{+TIMES};

    if ($is_exit) {
        push @out => $self->_transition('completed');
        push @out => $self->_final_state_event;
    }

    return @out;
}

sub pass ($self) { return $self->fail ? 0 : 1 }

sub fail ($self) {
    return $self->{+FAIL}     if $self->{+FAIL};
    return $self->{+FAIL} = 1 if $self->fail_error_facet_list;
    return 0;
}

sub fail_count ($self) {
    my $count = $self->{+_FAILURES} + $self->{+_ERRORS} + $self->{+_SUB_FAILURES};
    $count++ if $self->{+HALT};
    $count++ if defined($self->{+EXIT}) && $self->{+EXIT} != 0;
    $count++ if !$count                 && $self->{+FAIL};
    return $count;
}

sub pass_count ($self) {
    my $passes = $self->{+ASSERTION_COUNT} - $self->{+_FAILURES};
    return $passes < 0 ? 0 : $passes;
}

sub has_exit ($self) { return defined $self->{+EXIT} }
sub has_plan ($self) { return defined $self->{+PLAN} }

sub final_state ($self) {
    my %state = (
        pass            => $self->pass ? 1 : 0,
        fail_count      => $self->fail_count,
        pass_count      => $self->pass_count,
        assertion_count => $self->{+ASSERTION_COUNT} // 0,
        exit            => $self->{+EXIT},
        subtests        => [@{$self->{+TOP_LEVEL_SUBTESTS} // []}],
    );

    $state{plan}  = $self->{+PLAN} if defined $self->{+PLAN};
    $state{halt}  = $self->{+HALT} if defined $self->{+HALT};
    $state{times} = $self->{+TIMES}->totals
        if $self->{+TIMES} && $self->{+TIMES}->useful;

    return \%state;
}

sub subtest_fail_error_facet_list ($self) {
    my @out;

    my $plan  = $self->{+PLAN} ? $self->{+PLAN}{count} : undef;
    my $count = $self->{+ASSERTION_COUNT};

    my $numbers = $self->{+NUMBERS};
    my $max     = max(keys %$numbers);
    if ($max) {
        for my $i (1 .. $max) {
            push @out => $self->_reason("Assertion number $i was never seen")
                if !$numbers->{$i};
            push @out => $self->_reason("Assertion number $i was seen more than once")
                if $numbers->{$i} && $numbers->{$i} > 1;
        }
    }

    if (!$self->{+_PLANS}) {
        push @out => $self->_reason($count ? "No plan was declared" : "No plan was declared, and no assertions were made.");
    }
    elsif ($self->{+_PLANS} > 1) {
        push @out => $self->_reason("Too many plans were declared (Count: $self->{+_PLANS})");
    }

    push @out => $self->_reason("Planned for $plan assertions, but saw $count")
        if $plan && $count != $plan;

    push @out => $self->_reason("Subtest failures were encountered (Count: $self->{+_SUB_FAILURES})")
        if $self->{+_SUB_FAILURES};

    return @out;
}

sub fail_error_facet_list ($self) {
    my @out;

    my $incomplete = values %{$self->{+SUBTESTS}};
    push @out => $self->_reason("One or more incomplete subtests (Count: $incomplete)")
        if $incomplete;

    if (defined(my $wstat = $self->{+EXIT})) {
        if ($wstat == -1) {
            push @out => $self->_reason("The harness could not get the exit code! (Code: $wstat)");
        }
        elsif ($wstat) {
            my $e = parse_exit($wstat);
            push @out => $self->_reason("Test script returned error (Err: $e->{err})")    if $e->{err};
            push @out => $self->_reason("Test script returned error (Signal: $e->{sig})") if $e->{sig};
        }
    }

    push @out => $self->_reason("Errors were encountered (Count: $self->{+_ERRORS})")
        if $self->{+_ERRORS};

    push @out => $self->_reason("Assertion failures were encountered (Count: $self->{+_FAILURES})")
        if $self->{+_FAILURES};

    push @out => $self->subtest_fail_error_facet_list;

    return @out;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $facet = $self->_reason($details)

Build a harness failure-reason error facet.

=item @events = $self->_audit($event)

Core auditing of one event: identify its nesting via the hub-truth facet,
buffer the children of streaming subtests, reassemble and process closed
subtests, and tally events that belong to this auditor's level.

=item $event = $self->_transition($state)

=item $event = $self->_final_state_event

Build a state-transition / final-state event.

=item $bool = $self->_event_is_failing($f)

=item $bool = $self->_event_is_diagnostic($f)

Whether an event's facets indicate a failure / diagnostic output (for the
transition latches).

=item @events = $self->_audit_subtest_start($event, $f, $nested, $is_ours)

Begin buffering a streaming subtest; for our own level, return a
C<subtest_started> announcement event.

=item ($event, $f) = $self->_audit_orphan_subtest_end_recovery($event, $f)

Rewrite a stray TAP subtest-end with no open subtest into an info-only event.

=item @events = $self->_audit_close_deeper_subtests($event, $nested)

Close any buffered subtests deeper than C<$nested>, rolling each into a
buffered parent event and (at our level) processing it.

=item $self->_subtest_process($f, $event = undef)

Tally one event/facet-set: record its assertion number, recurse into a
buffered subtest, fold its facets into the running totals, and handle the
process-exit facet.

=item $self->_subtest_process_parent($f, $closer)

Audit a buffered subtest's children with a fresh sub-auditor, decide the
subtest's pass/fail, and roll it into this auditor's counts and summary.

=item $self->_subtest_tally_facets($f)

Fold one facet-set's assertion / plan / error / control facets into totals.

=item $self->_subtest_process_exit($f, $event)

Record the child's exit status and attach the failure reasons to the
process-exit event.

=back

=cut

sub _reason ($self, $details) {
    return {tag => 'REASON', fail => 1, from_harness => 1, details => $details};
}

sub _transition ($self, $state) {
    return Test2::Harness2::Event->new(
        facet_data => {harness_state_transition => {state => $state, stamp => time}},
    );
}

sub _final_state_event ($self) {
    return Test2::Harness2::Event->new(
        facet_data => {harness_final_state => {%{$self->final_state}, stamp => time}},
    );
}

sub _event_is_failing ($self, $f) {
    if (my $assert = $f->{assert}) {
        return 1 if !$assert->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
    }

    if (my $errors = $f->{errors}) {
        return 1 if first { $_->{fail} } @$errors;
    }

    if (my $ctrl = $f->{control}) {
        return 1 if $ctrl->{halt} || $ctrl->{terminate};
    }

    return 0;
}

sub _event_is_diagnostic ($self, $f) {
    for my $src (qw/from_stream from_tap/) {
        my $from = $f->{$src} or next;
        return 1 if defined($from->{source}) && uc($from->{source}) eq 'STDERR';
    }

    if (my $info = $f->{info}) {
        return 1 if first { $_->{important} || $_->{debug} } @$info;
    }

    return 0;
}

sub _audit ($self, $event) {
    my $f  = $event->facet_data;
    my $hf = hub_truth($f);

    my $nested = $hf->{nested} || 0;

    return $event if $hf->{buffered};

    my $is_ours = $nested == $self->{+NESTED};

    return $event unless $is_ours || $f->{from_tap};

    return $event if $f->{from_tap}    && $f->{from_tap}{source} eq 'STDERR';
    return $event if $f->{from_stream} && $f->{from_stream}{source} eq 'STDERR';

    return $self->_audit_subtest_start($event, $f, $nested, $is_ours)
        if $f->{harness} && $f->{harness}{subtest_start};

    ($event, $f) = $self->_audit_orphan_subtest_end_recovery($event, $f)
        if $f->{from_tap}
        && $f->{harness}
        && $f->{harness}{subtest_end}
        && !keys %{$self->{+SUBTESTS}};

    my @out;
    push @out => $event
        unless $f->{harness} && $f->{harness}{subtest_end};

    push @out => $self->_audit_close_deeper_subtests($event, $nested);

    unless ($is_ours) {
        my $st = $self->{+SUBTESTS}{$nested} ||= {};
        push @{$st->{children}} => {%$f};
        return @out;
    }

    $self->_subtest_process($f, $event);
    return @out;
}

sub _audit_subtest_start ($self, $event, $f, $nested, $is_ours) {
    my $st = $self->{+SUBTESTS}{$nested + 1} ||= {};
    $st->{event} = $event;
    $f->{harness_auditor}{no_render} = 1;
    $event->clear_compressed_form;

    return unless $is_ours;

    return Test2::Harness2::Event->new(
        facet_data => {
            harness => {subtest_started => 1, nested => $nested},
            (defined $f->{trace} ? (trace => {%{$f->{trace}}}) : ()),
        },
    );
}

sub _audit_orphan_subtest_end_recovery ($self, $event, $f) {
    $f->{harness_auditor}{no_render} = 1;
    $event->clear_compressed_form;

    $f = {
        %$f,
        harness_auditor => {added_by_auditor => 1},
        parent          => undef,
        trace           => undef,
        harness         => {%{$f->{harness} || {}}, subtest_end => undef},
        info            => [
            @{$f->{info} || []},
            {
                details      => $f->{from_tap}{details},
                tag          => $f->{from_tap}{source} || 'STDOUT',
                from_harness => 1,
            },
        ],
    };

    return (Test2::Harness2::Event->new(facet_data => $f), $f);
}

sub _audit_close_deeper_subtests ($self, $event, $nested) {
    my $sts = $self->{+SUBTESTS};

    my @close = sort { $b <=> $a } grep { $_ > $nested } keys %$sts;
    return unless @close;

    my @out;
    for my $n (@close) {
        my $st = delete $sts->{$n};
        my $se = $st->{event} || $event;

        my $fd = $se->facet_data;
        delete $fd->{harness_auditor}{no_render} if $fd->{harness_auditor};
        $fd->{parent}{hid}      ||= $n;
        $fd->{parent}{children} ||= $st->{children};
        $fd->{harness}{closed_by} = $event;
        $se->clear_compressed_form;

        my $pn = $n - 1;

        if ($st->{event}) {
            push @{$sts->{$pn}{children}} => $fd if $pn > $self->{+NESTED};
            if ($pn == $self->{+NESTED}) {
                $self->_subtest_process($fd, $se);
                push @out => $se;
            }
        }
        else {
            push @out => $se if $self->{+NESTED} && $pn == $self->{+NESTED};
        }
    }

    return @out;
}

sub _subtest_process ($self, $f, $event = undef) {
    $event->clear_compressed_form if $event;

    my $closer = $f->{harness} ? delete $f->{harness}{closed_by} : undef;

    $event //= Test2::Harness2::Event->new(facet_data => $f);

    $self->{+NUMBERS}{$f->{assert}{number}}++
        if $f->{assert} && $f->{assert}{number};

    $self->_subtest_process_parent($f, $closer)
        if $f->{parent} && $f->{assert};

    $self->_subtest_tally_facets($f);

    $self->_subtest_process_exit($f, $event)
        if $f->{harness_process_exit};

    return;
}

sub _subtest_process_parent ($self, $f, $closer) {
    my $name = $f->{assert}{details};
    unless (defined $name) {
        my $frame = $f->{trace} && $f->{trace}{frame};
        $name = $frame ? "unnamed subtest ($frame->[1] line $frame->[2])" : 'unnamed subtest';
    }

    my $subauditor = blessed($self)->new(nested => $self->{+NESTED} + 1);
    $subauditor->_subtest_process($_) for @{$f->{parent}{children}};
    my @errors = $subauditor->subtest_fail_error_facet_list;

    if ($f->{harness} && $f->{harness}{subtest_start}) {
        if ($closer && $closer->facet_data->{harness} && $closer->facet_data->{harness}{subtest_end}) {
            $f->{harness}{subtest_closed} = 1;
        }
        elsif (!$f->{harness}{subtest_closed}) {
            push @{$f->{errors}} => $self->_reason("Buffered subtest ended abruptly (missing closing brace event)");
        }
    }

    my $fail = 0;
    if (@errors) {
        push @{$f->{errors}} => @errors;
        $fail = 1;
    }
    else {
        $fail ||= $f->{assert}  && !$f->{assert}{pass} && !($f->{amnesty} && @{$f->{amnesty}});
        $fail ||= $f->{control} && ($f->{control}{halt} || $f->{control}{terminate});
        $fail ||= $f->{errors}  && first { $_->{fail} } @{$f->{errors}};
    }

    if ($fail) {
        $self->{+_SUB_FAILURES}++;
        push @{$self->{+FAILED_SUBTEST_TREE} //= []} => [$name, $subauditor->{+FAILED_SUBTEST_TREE} // []];
        push @{$self->{+FAILING_SUBTESTS}}           => $name;
    }
    else {
        push @{$self->{+PASSING_SUBTESTS}} => $name;
    }

    push @{$self->{+TOP_LEVEL_SUBTESTS}} => {
        name       => $name,
        pass       => $fail ? 0 : 1,
        count_pass => $subauditor->pass_count,
        count_fail => $subauditor->fail_count,
    } if $self->{+NESTED} == 0;

    return;
}

sub _subtest_tally_facets ($self, $f) {
    $self->{+ASSERTION_COUNT}++ if $f->{assert};

    $self->{+_FAILURES}++
        if $f->{assert} && !$f->{assert}{pass} && !($f->{amnesty} && @{$f->{amnesty}});

    if ($f->{control} || $f->{errors}) {
        my $err = $f->{control} && ($f->{control}{halt} || $f->{control}{terminate});
        $err ||= $f->{errors} && first { $_->{fail} } @{$f->{errors}};
        $self->{+_ERRORS}++ if $err;
        $self->{+HALT} = $f->{control}{details} || '1'
            if $f->{control} && $f->{control}{halt} && (!$self->{+HALT} || $self->{+HALT} eq '1');
    }

    if ($f->{plan} && !$f->{plan}{none}) {
        $self->{+_PLANS}++;
        $self->{+PLAN} = $f->{plan};
    }

    return;
}

sub _subtest_process_exit ($self, $f, $event) {
    my $px = $f->{harness_process_exit};
    $self->{+EXIT} = $px->{all};

    my $stamp = ($f->{trace} && $f->{trace}{stamp}) // time;

    $f->{harness_job_exit} //= {
        exit  => $px->{all},
        codes => $px,
        stamp => $stamp,
        (defined $px->{times} ? (times => $px->{times}) : ()),
    };

    push @{$f->{errors}} => $self->fail_error_facet_list;
    return;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
