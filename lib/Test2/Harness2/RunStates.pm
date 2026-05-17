package Test2::Harness2::RunStates;
use strict;
use warnings;

our $VERSION = '2.000013';

use Object::HashBase qw{
    +run_states
    +run_flags
    +completed_runs
    +run_ord_counter
};

sub init {
    my $self = shift;
    $self->{+RUN_STATES}      //= {};
    $self->{+RUN_FLAGS}       //= {};
    $self->{+COMPLETED_RUNS}  //= {};
    $self->{+RUN_ORD_COUNTER} //= 0;
}

#-------------------------------------------------------------------
# RUN_STATES accessors -- the per-run Test2::Harness2::Run::State
# objects the harness mirrors run lifecycle into.
#-------------------------------------------------------------------

sub state {
    my ($self, $run_id) = @_;
    return $self->{+RUN_STATES}->{$run_id};
}

sub set_state {
    my ($self, $run_id, $state) = @_;
    $self->{+RUN_STATES}->{$run_id} = $state;
    return $state;
}

sub delete_state {
    my ($self, $run_id) = @_;
    return delete $self->{+RUN_STATES}->{$run_id};
}

sub all_run_ids {
    my $self = shift;
    return keys %{$self->{+RUN_STATES}};
}

#-------------------------------------------------------------------
# RUN_FLAGS accessors -- per-run side state (first-fail latch,
# completed-job idempotency guard, per-job result snapshots that feed
# the eventual aggregate verdict). Distinct from RUN_STATES so the
# harness can drop the mirror Run::State without losing the bookkeeping
# fields the renderer / collector_report aggregator still needs.
#-------------------------------------------------------------------

# Lazy-initialize the flags hash for $run_id with the canonical default
# shape. Idempotent. Replaces the harness's old _run_flags helper so
# callers (in-process and tests) share one shape.
sub flags {
    my ($self, $run_id) = @_;
    return $self->{+RUN_FLAGS}->{$run_id} //= {
        completed_job_ids    => {},
        completed_job_states => {},
        failing_emitted      => 0,
        pass                 => 1,
    };
}

# Peek at the flags hash without lazy-initializing. Returns undef when
# no entry exists. Used by paths that want to skip work entirely when
# nothing has been recorded yet (e.g. _emit_run_completed).
sub flags_peek {
    my ($self, $run_id) = @_;
    return $self->{+RUN_FLAGS}->{$run_id};
}

sub delete_flags {
    my ($self, $run_id) = @_;
    return delete $self->{+RUN_FLAGS}->{$run_id};
}

#-------------------------------------------------------------------
# COMPLETED_RUNS accessors -- terminal snapshots produced once a run's
# Run::State reaches is_complete, used to serve later
# request_handler_run_results queries.
#-------------------------------------------------------------------

sub record_completed {
    my ($self, $run_id, $result) = @_;
    $self->{+COMPLETED_RUNS}->{$run_id} = $result;
    return $result;
}

sub completed {
    my ($self, $run_id) = @_;
    return $self->{+COMPLETED_RUNS}->{$run_id};
}

sub all_completed_ids {
    my $self = shift;
    return keys %{$self->{+COMPLETED_RUNS}};
}

#-------------------------------------------------------------------
# RUN_ORD_COUNTER -- sequential run-ord allocator. Every accepted run
# gets the next ordinal integer starting at the counter's current
# value (callers historically seeded this to 1; the default is 0
# here so a fresh RunStates can stand alone in tests).
#-------------------------------------------------------------------

# Postfix-increment: returns the current value, then bumps the counter.
# Matches the pre-extraction `$self->{+RUN_ORD_COUNTER}++` semantics
# on the harness exactly.
sub next_ord {
    my $self = shift;
    return $self->{+RUN_ORD_COUNTER}++;
}

#-------------------------------------------------------------------
# Bulk reset hooks. service_post_hard_stop clears the per-run flag
# bookkeeping wholesale; expose a single entry point so the harness
# does not poke the raw slot.
#-------------------------------------------------------------------

sub clear_flags {
    my $self = shift;
    $self->{+RUN_FLAGS} = {};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::RunStates - In-process state holder for per-run mirror state.

=head1 DESCRIPTION

C<RunStates> is the harness's per-run state holder. It owns four
related caches:

=over 4

=item RUN_STATES

The per-run L<Test2::Harness2::Run::State> mirrors the harness keeps in
process, keyed by C<run_id>. Mutated by the test_job_* / collector_*
handlers as the run progresses.

=item RUN_FLAGS

Per-run side state distinct from C<Run::State>: the first-fail latch,
the completed-job idempotency guard, the per-job state snapshots that
feed the eventual aggregate verdict, and the C<started_at> stamp.
Lives on its own so the harness can drop the mirror Run::State at run
finalization without losing the data the collector_report aggregator
still needs.

=item COMPLETED_RUNS

Terminal snapshots produced once a run's C<Run::State> reaches
C<is_complete>. Served by C<request_handler_run_results> for clients
that poll after run end but before the harness exits.

=item RUN_ORD_COUNTER

Sequential run-ord allocator: every accepted run gets the next ordinal
integer. Counter is per harness process; persistent runners reuse the
same harness so ords climb monotonically across runs in a session,
with gaps possible (e.g. accepted-then-purged runs).

=back

C<RunStates> is a pure data object. It holds no behavior beyond
accessors and does not consume L<Test2::Harness2::Role::Subsystem> --
there is no harness backref, no weakening, and no peer collaborators.
The harness constructs one C<RunStates> during its own C<init> and
hands the reference to every subsystem that needs to read or mutate
per-run state (broadcaster, scheduler, job tracker).

=head1 METHODS

=head2 RUN_STATES

=over 4

=item $state = $rs->state($run_id)

Returns the L<Test2::Harness2::Run::State> mirror for C<$run_id>, or
C<undef> when none has been registered.

=item $rs->set_state($run_id, $state)

Stores C<$state> as the mirror for C<$run_id>.

=item $rs->delete_state($run_id)

Drops the mirror entry for C<$run_id>. Returns the dropped value.

=item @run_ids = $rs->all_run_ids

Returns every C<run_id> currently registered. Unordered.

=back

=head2 RUN_FLAGS

=over 4

=item $flags = $rs->flags($run_id)

Lazy-initializes (and returns) the flags hash for C<$run_id> with the
canonical default shape. Idempotent.

=item $flags = $rs->flags_peek($run_id)

Returns the flags hash for C<$run_id> without creating one. Returns
C<undef> when no entry exists.

=item $rs->delete_flags($run_id)

Drops the flags entry for C<$run_id>.

=item $rs->clear_flags

Wipes every flags entry. Used by the harness's wholesale
C<service_post_hard_stop> reset; not normally called otherwise.

=back

=head2 COMPLETED_RUNS

=over 4

=item $rs->record_completed($run_id, $result)

Stash the terminal snapshot for C<$run_id>. C<$result> is the hashref
the harness builds via its run-snapshot helper.

=item $info = $rs->completed($run_id)

Returns the terminal snapshot for C<$run_id>, or C<undef>.

=item @run_ids = $rs->all_completed_ids

Returns every C<run_id> that has a terminal snapshot. Unordered.

=back

=head2 RUN_ORD_COUNTER

=over 4

=item $n = $rs->next_ord

Postfix-increment: returns the counter's current value, then bumps it
by one. Matches the C<$counter++> semantics the harness used inline
before extraction.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Run::State>,
L<Test2::Harness2::StateBroadcaster>.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
