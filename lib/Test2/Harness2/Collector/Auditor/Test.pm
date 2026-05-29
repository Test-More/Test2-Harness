package Test2::Harness2::Collector::Auditor::Test;
use v5.38;

our $VERSION = '2.000000';

use List::Util qw/any/;
use Time::HiRes qw/time/;

use Test2::Harness2::Event;

use Object::HashBase qw{
    -assertion_count
    -failures
    -errors
    -exit
    -plan
    -plans
    -halt
    -started
    -state_failing
    -state_diagnosing
};

use Role::Tiny::With;
with 'Test2::Harness2::Collector::Role::Processor';

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Collector::Auditor::Test - Collector processor that audits a
test job's event stream.

=head1 DESCRIPTION

The auditor sits in the processor slot of the collector pipeline. It receives
each parsed L<Test2::Harness2::Event> in turn and:

=over 4

=item *

passes every event through unchanged;

=item *

tracks the running test's verdict (assertions, plan, errors, bail-out, and
the child's exit status);

=item *

emits B<state-transition events> as additional events when the test first
starts, first fails, first produces diagnostics, and completes; and

=item *

emits a B<final-state event> once it sees the synthetic process-exit event.

=back

State-transition events carry a C<harness_state_transition> facet
(C<< { state => $name, stamp => $epoch } >>) whose C<state> is one of
C<starting>, C<failing>, C<diagnosing>, or C<completed>. The final-state
event carries a C<harness_final_state> facet holding the verdict snapshot
returned by L</final_state>. A test-aware recorder routes these to separate
files; a plain recorder simply records them like any other event.

Only top-level assertions and plans (nesting depth zero) count toward the
verdict, so a buffered subtest's children are not double-counted against the
parent's summary assertion.

=head1 SYNOPSIS

    use Test2::Harness2::Collector::Auditor::Test;

    my $auditor = Test2::Harness2::Collector::Auditor::Test->new;
    my @out     = $auditor->process_event($event);   # 1+ events

    my $verdict = $auditor->final_state;             # after the run

=head1 ATTRIBUTES

The auditor takes no construction arguments; all state is internal and is
reached through the methods below.

=cut

sub init ($self) {
    $self->{+ASSERTION_COUNT}  = 0;
    $self->{+FAILURES}         = 0;
    $self->{+ERRORS}           = 0;
    $self->{+PLANS}            = 0;
    $self->{+STARTED}          = 0;
    $self->{+STATE_FAILING}    = 0;
    $self->{+STATE_DIAGNOSING} = 0;

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item @events = $auditor->process_event($event)

Account for C<$event>, then return the events to record: the original event,
preceded on the first call by a C<starting> transition, and followed by any
C<failing> / C<diagnosing> transition that newly latched. When C<$event> is
the synthetic process-exit event, the returned list is the exit event, a
C<completed> transition, and the final-state event, in that order.

=back

=cut

sub process_event ($self, $event) {
    my @out;

    unless ($self->{+STARTED}) {
        $self->{+STARTED} = 1;
        push @out => $self->_transition('starting');
    }

    my $f = $event->facet_data;

    if (my $exit = $f->{harness_process_exit}) {
        $self->{+EXIT} = $exit->{all} // 0;
        push @out => $event;
        push @out => $self->_transition('completed');
        push @out => $self->_final_state_event;
        return @out;
    }

    my $newly = $self->_account($f);

    push @out => $event;
    push @out => $self->_transition('failing')    if $newly->{failing};
    push @out => $self->_transition('diagnosing') if $newly->{diagnosing};

    return @out;
}

=over 4

=item $n = $auditor->assertion_count

Total top-level assertions seen.

=item $n = $auditor->pass_count

Top-level assertions that did not fail (never negative).

=item fail_count

=item $n = $auditor->fail_count

Number of distinct failure reasons: failing assertions, failing error facets,
a bail-out, a non-zero child exit, and a duplicated plan each contribute one.

=item $bool = $auditor->passing

=item $bool = $auditor->failing

True / false verdict, derived from L</fail_count>.

=item final_state

=item $state = $auditor->final_state

Hashref verdict snapshot: C<pass>, C<fail_count>, C<pass_count>,
C<assertion_count>, and C<exit>, plus C<plan> and C<halt> when seen.

=back

=cut

sub pass_count ($self) {
    my $passes = $self->{+ASSERTION_COUNT} - $self->{+FAILURES};
    return $passes < 0 ? 0 : $passes;
}

sub fail_count ($self) {
    my $count = $self->{+FAILURES} + $self->{+ERRORS};
    $count++ if defined $self->{+HALT};
    $count++ if $self->{+EXIT};
    $count++ if $self->{+PLANS} > 1;
    return $count;
}

sub passing ($self) { return $self->fail_count ? 0 : 1 }
sub failing ($self) { return $self->fail_count ? 1 : 0 }

sub final_state ($self) {
    my %state = (
        pass            => $self->passing,
        fail_count      => $self->fail_count,
        pass_count      => $self->pass_count,
        assertion_count => $self->{+ASSERTION_COUNT},
        exit            => $self->{+EXIT},
    );

    $state{plan} = $self->{+PLAN} if defined $self->{+PLAN};
    $state{halt} = $self->{+HALT} if defined $self->{+HALT};

    return \%state;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $newly = $self->_account($f)

Fold one event's facet hash into the running tallies and latch the C<failing>
/ C<diagnosing> states. Returns a hashref noting which of those states newly
latched on this event so the caller can emit the matching transition once.

=item $depth = $self->_nesting($f)

Subtest nesting depth of an event (C<trace.nested>, else C<hubs[0].nested>,
else 0).

=item $bool = $self->_event_is_diagnostic($f)

True when an event represents diagnostic output: a STDERR-sourced line, or an
C<info> entry flagged C<important> or C<debug>.

=item $event = $self->_transition($state)

Build a state-transition event for C<$state>.

=item $event = $self->_final_state_event

Build the final-state event from L</final_state>.

=back

=cut

sub _account ($self, $f) {
    my %newly;

    if ($self->_nesting($f) == 0) {
        if (my $assert = $f->{assert}) {
            $self->{+ASSERTION_COUNT}++;
            $self->{+FAILURES}++
                if !$assert->{pass} && !($f->{amnesty} && @{$f->{amnesty}});
        }

        if (my $plan = $f->{plan}) {
            $self->{+PLAN} = $plan;
            $self->{+PLANS}++;
        }
    }

    if (my $errors = $f->{errors}) {
        $self->{+ERRORS} += grep { $_->{fail} } @$errors;
    }

    if (my $ctrl = $f->{control}) {
        $self->{+HALT} //= $ctrl->{details} // 'halt'
            if $ctrl->{halt} || $ctrl->{terminate};
    }

    if (!$self->{+STATE_FAILING} && ($self->{+FAILURES} || $self->{+ERRORS} || defined $self->{+HALT})) {
        $self->{+STATE_FAILING} = 1;
        $newly{failing} = 1;
    }

    if (!$self->{+STATE_DIAGNOSING} && $self->_event_is_diagnostic($f)) {
        $self->{+STATE_DIAGNOSING} = 1;
        $newly{diagnosing} = 1;
    }

    return \%newly;
}

sub _nesting ($self, $f) {
    return $f->{trace}{nested}
        if $f->{trace} && defined $f->{trace}{nested};

    return $f->{hubs}[0]{nested}
        if $f->{hubs} && $f->{hubs}[0] && defined $f->{hubs}[0]{nested};

    return 0;
}

sub _event_is_diagnostic ($self, $f) {
    for my $src (qw/from_stream from_tap/) {
        my $from = $f->{$src} or next;
        return 1 if defined($from->{source}) && uc($from->{source}) eq 'STDERR';
    }

    if (my $info = $f->{info}) {
        return 1 if any { $_->{important} || $_->{debug} } @$info;
    }

    return 0;
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
