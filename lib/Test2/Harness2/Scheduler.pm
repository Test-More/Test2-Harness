package Test2::Harness2::Scheduler;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;

use Object::HashBase qw{
    +queue
    +scheduler
    +in_flight_count
    +broken_resource_behavior
    +harness
    +run_states
    +pid_index
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

# Valid values for broken_resource_behavior: what the scheduler does
# when a job needs a resource that has been flipped to
# permanent_broken. All three paths route the job through a real
# Collector launch so the on-disk artifacts match a real test's --
# see launch_unavailable_action.
#
#   skip  - launch `perl -e 'use Test2::V0; skip_all ...'` so the
#           job's log looks like a regular test that called skip_all.
#   fail  - launch `perl -e 'die ...'` so the job's log looks like a
#           regular test that failed with an uncaught exception
#           (exit 255 with the message on stderr).
#   abort - same as fail for THIS job plus every remaining pending
#           job in the same run, one at a time as the job limiter
#           frees slots; the run closes out once they all complete.
use constant BROKEN_BEHAVIORS => {map { $_ => 1 } qw/skip fail abort/};

sub init {
    my $self = shift;

    croak "'harness' is required"     unless $self->{+HARNESS};
    croak "'run_states' is required"  unless $self->{+RUN_STATES};
    croak "'pid_index' is required"   unless $self->{+PID_INDEX};

    $self->{+QUEUE}                    //= [];
    $self->{+SCHEDULER}                //= {};
    $self->{+IN_FLIGHT_COUNT}          //= 0;
    $self->{+BROKEN_RESOURCE_BEHAVIOR} //= 'skip';

    croak "invalid broken_resource_behavior '$self->{+BROKEN_RESOURCE_BEHAVIOR}' (want skip, fail, or abort)"
        unless BROKEN_BEHAVIORS->{$self->{+BROKEN_RESOURCE_BEHAVIOR}};

    return;
}

#-------------------------------------------------------------------
# Direct slot accessors for callers that need to inspect or mutate
# the scheduler's bookkeeping (broadcaster, harness shims, tests).
#-------------------------------------------------------------------

sub queue            { $_[0]->{+QUEUE} }
sub in_flight_count  { $_[0]->{+IN_FLIGHT_COUNT} }
sub scheduler_table  { $_[0]->{+SCHEDULER} }
sub broken_resource_behavior { $_[0]->{+BROKEN_RESOURCE_BEHAVIOR} }

# Scalar ref to the in-flight counter; Resources hold this so they can
# read live utilization without a per-mutation notification loop.
sub in_flight_ref { \$_[0]->{+IN_FLIGHT_COUNT} }

# Increment / decrement the in-flight counter from outside the
# scheduler (the launch-glue path on the harness still owns the
# increment; the job-release path owns the decrement). Returning the
# scheduler so call sites do not have to grab it twice.
sub inc_in_flight { $_[0]->{+IN_FLIGHT_COUNT}++; return $_[0] }
sub dec_in_flight { $_[0]->{+IN_FLIGHT_COUNT}--; return $_[0] }

# Reset hooks for service_pre_hard_stop / service_post_hard_stop.
sub clear_queue           { $_[0]->{+QUEUE} = []; return }
sub reset_in_flight_count { $_[0]->{+IN_FLIGHT_COUNT} = 0; return }

# Drop $run_id from the queue (used by finalize). Returns the dropped
# Run object(s).
sub remove_from_queue {
    my ($self, $run_id) = @_;
    my @kept;
    my @dropped;
    for my $r (@{$self->{+QUEUE} // []}) {
        if ($r->run_id eq $run_id) { push @dropped, $r }
        else                       { push @kept,    $r }
    }
    $self->{+QUEUE} = \@kept;
    return @dropped;
}

# True when $run_id is in the live queue. Used by the broadcaster.
sub run_in_queue {
    my ($self, $run_id) = @_;
    return 0 unless defined $run_id;
    for my $r (@{$self->{+QUEUE} // []}) {
        return 1 if $r->run_id eq $run_id;
    }
    return 0;
}

# Find a queued Run by id; returns the Run object or undef.
sub run_by_id {
    my ($self, $run_id) = @_;
    return undef unless defined $run_id;
    for my $r (@{$self->{+QUEUE} // []}) {
        return $r if $r->run_id eq $run_id;
    }
    return undef;
}

# Append a Run to the queue; returns the Run.
sub enqueue {
    my ($self, $run) = @_;
    push @{$self->{+QUEUE}} => $run;
    return $run;
}

#-------------------------------------------------------------------
# Scheduler-table state. The harness keeps its own pending/running
# view of every queued run, populated once at queue time from the
# run's initial job list and mutated only by the scheduler's own
# decisions (launch, skip, completion). It deliberately never reads
# or writes the Run object's pending/running/done arrays (those
# mirror what the auditors broadcast back, which the scheduler
# should not depend on -- the broadcasts can race and would
# otherwise resurrect already-launched jobs into the pending list).
#-------------------------------------------------------------------

sub queue_run {
    my ($self, $run) = @_;
    my $rid = $run->run_id;
    $self->{+SCHEDULER}->{$rid} = {
        pending => [map { $_->job_id } @{$run->jobs}],
        running => {},
        started => 0,
    };
    return;
}

sub pending_for_run {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return [];
    return $s->{pending};
}

sub is_running {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{running}->{$job_id} ? 1 : 0;
}

sub started {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{started};
}

sub mark_running {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    $s->{pending}            = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{running}->{$job_id} = 1;
    $s->{started}            = 1;
    return;
}

# Restore a job to the scheduler's pending queue. Used by the
# preload-spawn watchdog when an in-flight request times out: the
# placeholder RUNNING_JOBS entry is dropped and the job has to be
# eligible for relaunch on the next scheduler tick.
sub mark_pending {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    delete $s->{running}->{$job_id};
    return if grep { $_ eq $job_id } @{$s->{pending}};
    push @{$s->{pending}}, $job_id;
    return;
}

sub mark_done {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    delete $s->{running}->{$job_id};
    return;
}

sub skip {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    $s->{pending} = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{started} = 1;
    return;
}

sub drop_run {
    my ($self, $run_id) = @_;
    delete $self->{+SCHEDULER}->{$run_id};
    return;
}

sub run_complete {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id};
    return 1 unless $s;    # already dropped
    return 0 if @{$s->{pending}};
    return 0 if keys %{$s->{running}};

    # The scheduler has nothing left of its own to do for the run,
    # but the run is only really finished once we have also seen
    # the started flag flip -- otherwise an empty queue at startup
    # would look "complete" to us before we ever launched anything.
    return $s->{started} ? 1 : 0;
}

# Compact snapshot of the scheduler's per-run bookkeeping. Used by
# the harness's request_handler_status path so it can serve queue
# rows without poking the table directly.
sub snapshot {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return undef;
    return {
        pending => [@{$s->{pending}}],
        running => [keys %{$s->{running}}],
        started => $s->{started},
    };
}

#-------------------------------------------------------------------
# Tick entry point + per-job dispatch decision logic. Launch glue
# (collector fork, preload dispatch, RUNNING_JOBS bookkeeping) lives
# on the harness; the scheduler returns decisions and asks the
# harness to execute them via the harness backref.
#-------------------------------------------------------------------

# Called from the harness's run_on_all once per service tick: launch
# as many pending jobs as the active resources permit this tick.
sub try_launch_next {
    my $self = shift;

    return 0 unless @{$self->{+QUEUE} // []};

    # Runs are processed serially in the order they were queued. Find
    # the first run that is not yet complete from the scheduler's
    # perspective; that becomes the head run for this tick.
    my $head_run;
    for my $run (@{$self->{+QUEUE}}) {
        next if $self->run_complete($run->run_id);
        $head_run = $run;
        last;
    }
    return 0 unless $head_run;

    my $run_id = $head_run->run_id;

    # Lazy per-run resource startup: the first time this run is
    # considered for launch we spin up its resource services.
    my $h = $self->harness or return 0;
    $h->_ensure_run_service_started($head_run);

    # Iterate the scheduler's own pending list (authoritative view of
    # what we have not yet attempted), not $run->pending (mirrors the
    # auditors and can lag behind).
    for my $job_id (@{$self->pending_for_run($run_id)}) {
        my ($job) = grep { $_->job_id eq $job_id } @{$head_run->jobs};
        next unless $job;

        my $outcome = $self->dispatch_pending($head_run, $job);
        return 1 if $outcome eq 'launched';
        next;     # 'defer' or 'skipped'
    }

    return 0;
}

# Per-job dispatch decision for try_launch_next. Returns 'launched'
# to signal the caller a job was started (and the tick is done), or
# 'defer' to advance to the next pending job. Encapsulates the
# run-aborted short-circuit, preload routing, and resource
# evaluation, plus the unavailable-action / broken-resource
# branches.
sub dispatch_pending {
    my ($self, $run, $job) = @_;

    my $h = $self->harness or return 'defer';

    my ($decision, $arg, %dec_opts);
    my $preload_resource;

    my $rstate = $self->{+RUN_STATES}->state($run->run_id);
    if ($rstate && defined $rstate->aborted_reason) {
        # Run aborted: every remaining job takes the unavailable-action
        # fail path. aborted=1 distinguishes follow-ups from the
        # original trigger (aborted=0, set by handle_broken_resource).
        ($decision, $arg) = ('broken', $rstate->aborted_reason);
        $dec_opts{aborted} = 1;
    }
    else {
        # Preload routing runs before the generic resource walk so an
        # unmet preload preference can short-circuit evaluate_resources
        # entirely. Resolver returns:
        #   (undef, 'no_preload')      -> normal direct-fork path
        #   ($resource, 'preload')     -> spawn via preload service
        #   (undef, 'defer')           -> retry next tick
        #   (undef, 'broken', $first)  -> route through broken_resource_behavior
        my ($pres, $pkind, $pextra) = $h->_resolve_preload_for_job($run, $job);
        return 'defer' if $pkind eq 'defer';

        if ($pkind eq 'broken') {
            ($decision, $arg) = ('broken', "preload:$pextra");
        }
        else {
            $preload_resource = $pres;
            ($decision, $arg) = $self->evaluate_resources($run, $job);
        }
    }

    if ($decision eq 'skip') {
        # Resource is healthy but can never grant the slots THIS job
        # demands (e.g. test declares `HARNESS2: slots 8` and per-job
        # cap is 4). Route through the unavailable-action skip launch
        # so the renderer/log show a real skip_all event. The skip
        # launch shares the job-limiter pool and may defer when
        # saturated.
        my $outcome = $self->launch_unavailable_action($run, $job, 'skip', $arg);
        return $outcome eq 'launched' || $outcome eq 'skip' ? 'launched' : 'defer';
    }

    if ($decision eq 'broken') {
        my $outcome = $self->handle_broken_resource($run, $job, $arg, %dec_opts);
        return $outcome eq 'launched' || $outcome eq 'skip' ? 'launched' : 'defer';
    }

    return 'defer' if $decision eq 'defer';

    $h->_launch_job(
        $run, $job, $arg,
        (defined $preload_resource ? (preload_resource => $preload_resource) : ()),
    );
    return 'launched';
}

# Walk the global + per-run resources for a job and return the
# launch decision. Return shape:
#   ('launch', \@use)
#   ('defer')
#   ('skip', $resource_name)
#       - resource is present but can never grant THIS specific job
#         (e.g. job's min_slots exceeds the resource's per-job
#         cap). Scheduler routes the job through the
#         unavailable-action skip launch so the user sees a real
#         skip_all event and the run still completes; other jobs
#         that fit the cap continue to use the resource.
#   ('broken', $resource_name)
#       - a needed resource has been flipped to permanent_broken.
#         Scheduler consults broken_resource_behavior to decide
#         skip / fail / abort.
sub evaluate_resources {
    my ($self, $run, $job) = @_;

    my $h = $self->harness or return ('defer');

    # Global resources are consulted first, then per-run resources
    # layered on top. Either set may defer, skip, or report a broken
    # resource; all-or-nothing commitment is preserved because we
    # only call assign() in _launch_job after the entire walk returns
    # ('launch', \@use).
    my @all = (@{$h->resources // []}, @{$run->resources // []});

    my @use;
    for my $res (@all) {
        next unless $res->needed(job => $job);

        return ('broken', $res->resource_name) if $res->is_permanent_broken;

        # Transient brokenness / paused state: try again later.
        return ('defer') unless $res->is_usable;

        # Utilizer saturation: defer when min_concurrent floor met AND saturated.
        # Resource derefs the scheduler's IN_FLIGHT_COUNT slot via the
        # scalar ref installed at registration time.
        return ('defer')
            if $res->can('should_defer_for_utilization')
            && $res->should_defer_for_utilization;

        my $av = $res->available(job => $job);
        return ('skip', $res->resource_name) if $av < 0;
        return ('defer')                     if !$av;

        push @use => $res;
    }

    return ('launch', \@use);
}

# Dispatch for ($decision eq 'broken'): a needed resource is
# permanently broken. Which of skip / fail / abort to do is
# governed by the harness-level broken_resource_behavior attribute.
#
# All three paths route the job through a real Collector launch --
# skip runs a one-liner that calls skip_all, fail runs a one-liner
# that dies, abort is per-job fail for the whole remaining run.
# That way the auditor and on-disk artifacts are produced the same
# way they would be for a real test; no job is ever silently
# dropped.
#
# Returns 'launched', 'defer' (limiter full), or 'skip' (the
# unavailable-action launch is impossible: e.g. no job-limiter is
# usable any more).
sub handle_broken_resource {
    my ($self, $run, $job, $resource_name, %opts) = @_;

    my $behavior = $self->{+BROKEN_RESOURCE_BEHAVIOR};
    my $aborted  = $opts{aborted} ? 1 : 0;

    if ($behavior eq 'skip') {
        return $self->launch_unavailable_action(
            $run, $job, 'skip', $resource_name, aborted => $aborted,
        );
    }

    if ($behavior eq 'fail') {
        return $self->launch_unavailable_action(
            $run, $job, 'fail', $resource_name, aborted => $aborted,
        );
    }

    # abort: record the reason on the run state so every other
    # pending job also takes the fail path (see dispatch_pending),
    # then synthesize fail for THIS job. The scheduler drives the
    # rest one at a time as the job limiter frees slots -- we never
    # try to launch N synth-fail jobs against a single-slot limiter
    # at once. The current job is the trigger; follow-ups arrive
    # through the scheduler's aborted-run branch with aborted => 1
    # already set on their dec_opts.
    if (my $rstate = $self->{+RUN_STATES}->state($run->run_id)) {
        $rstate->latch_aborted_reason($resource_name);
    }
    return $self->launch_unavailable_action(
        $run, $job, 'fail', $resource_name, aborted => $aborted,
    );
}

# Launch an unavailable-action skip/fail via the normal Collector
# path, using a perl -e one-liner instead of the real test file.
# Only job_limiter resources that are NOT permanent_broken get
# consulted (with a fixed need=1) -- the broken resource itself is
# of course skipped, and non-limiter resources don't participate in
# accounting for one-off unavailable-action runs.
#
# Returns 'launched', 'defer' (limiter full right now), or 'skip'
# (no usable limiter at all, so the unavailable-action launch can
# never run).
sub launch_unavailable_action {
    my ($self, $run, $job, $unavailable_action, $resource_name, %opts) = @_;

    croak "unavailable_action kind must be 'skip' or 'fail' (got '$unavailable_action')"
        unless $unavailable_action eq 'skip' || $unavailable_action eq 'fail';

    my $h = $self->harness or return 'defer';

    my $aborted = $opts{aborted} ? 1 : 0;
    my $reason =
        $aborted
        ? "Run aborted: missing resources: $resource_name"
        : "Missing resources: $resource_name";

    # perl -Ilib -e ... -- <reason>. ARGV carries the reason so we
    # don't have to quote the message into the -e body. -Ilib mirrors
    # the real-test launch in the harness so Test2::Formatter::Stream2
    # (and any other @INC-dependent harness plumbing) resolves the
    # same way it does under a real test.
    my $script =
        $unavailable_action eq 'skip'
        ? 'use Test2::V0; skip_all($ARGV[0])'
        : 'die "$ARGV[0]\n"';
    my $launch = [$^X, '-Ilib', '-e', $script, '--', $reason];

    # Pull every resource the scheduler would have consulted for this
    # synthetic job: anything the resource itself reports as
    # `needed(job => $job)` and that has not been permanent-broken.
    # The `is_job_limiter` filter is gone; resources that genuinely
    # have no slot footprint for a synthetic skip/fail (e.g. a GPU
    # gating resource) are expected to opt themselves out via
    # `needed`.
    my @all = (@{$h->resources // []}, @{$run->resources // []});
    my @limiters =
        grep { !$_->is_permanent_broken && $_->needed(job => $job) } @all;

    # Availability gate: share the run's job-limiter pool with real
    # tests. If every usable limiter is saturated right now, defer
    # and let the scheduler re-try on the next tick once a slot
    # frees. If a limiter can never accommodate us (-1, which should
    # not happen with need=1 on a single-slot pool but is possible in
    # pathological configurations) the unavailable-action job is
    # skipped outright.
    for my $res (@limiters) {
        my $av = $res->available(job => $job, min => 1, max => 1, need => 1);
        if ($av < 0) {
            $self->skip($run->run_id, $job->job_id);
            $self->finalize_run_if_complete($run);
            return 'skip';
        }
        return 'defer' if $av == 0;
    }

    $h->_launch_job(
        $run, $job, \@limiters,
        launch      => $launch,
        assign_args => {min => 1, max => 1, need => 1},
    );

    return 'launched';
}

# Finalize the run if it's complete: snapshot final results from
# the Run mirror, drop the run from the queue, tear down its per-
# run service, and transition the harness to finishing if we're
# in finish_after_initial_run mode.
#
# Finalization is gated by the Run mirror's is_complete: that is
# the auditors' authoritative "all jobs done, here are the final
# results" signal. The scheduler's own pending+running view is for
# launch decisions, not finalization -- it can reach empty before
# the mirror has the results we need to snapshot.
sub finalize_run_if_complete {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $h = $self->harness or return;
    my $run_states = $self->{+RUN_STATES};
    my $rstate     = $run_states->state($run_id);
    return unless $rstate && $rstate->is_complete;

    # Idempotent: if we already finalized this run, do nothing.
    return if $run_states->completed($run_id);

    $run_states->record_completed($run_id, $h->job_tracker->snapshot_run_results($run));

    # Emit the terminal run_completed + collector_report event from
    # the harness BEFORE the per-run state is dropped.
    $h->job_tracker->emit_run_completed($run);
    $h->_write_run_report($run);

    $self->remove_from_queue($run_id);
    $run_states->delete_state($run_id);
    $run_states->delete_flags($run_id);
    $self->drop_run($run_id);
    $h->_teardown_run_service($run);
    $h->emit_service_event(
        kind     => 'run_ended',
        run_data => {run_id => $run_id},
    );
    $h->{Test2::Harness2::STATE()} = 'finishing'
        if $h->{Test2::Harness2::FINISH_AFTER_INITIAL_RUN()}
        && $h->{Test2::Harness2::STATE()} eq 'running';

    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Scheduler - Run queue, scheduling decisions, and broken-resource policy for the harness.

=head1 DESCRIPTION

The scheduler owns the harness's run queue and per-run pending/running
bookkeeping, plus the dispatch logic that turns a queued job into a
launch decision. The actual launch (collector fork, preload dispatch,
RUNNING_JOBS bookkeeping) lives on L<Test2::Harness2>; the scheduler
returns decisions and asks the harness to execute them via the
harness backref.

The harness constructs one scheduler during its own C<init> and holds
a strong reference to it. The scheduler holds a weakened backref to
the harness via L<Test2::Harness2::Role::Subsystem> for the launch
glue and resource list, plus direct (strong) references to
L<Test2::Harness2::RunStates> and L<Test2::Harness2::PidIndex>
because those state objects are first-class peers the scheduler
needs to read on every tick.

The scheduler also owns C<broken_resource_behavior>: when a needed
resource is permanently broken the scheduler routes the job through
one of skip / fail / abort by launching a synthetic C<perl -e>
one-liner so the on-disk artifacts and renderer output stay
consistent with a real test.

=head1 CONSTANTS

=over 4

=item BROKEN_BEHAVIORS

Hashref of valid C<broken_resource_behavior> values: C<skip>, C<fail>,
C<abort>. Used by the constructor to validate the argument.

=back

=head1 METHODS

=head2 Queue

=over 4

=item $aref = $sch->queue

Returns the live queue arrayref (the list of L<Test2::Harness2::Run>
objects awaiting or in progress).

=item $bool = $sch->run_in_queue($run_id)

True when a run with the given id is in the live queue.

=item $run = $sch->run_by_id($run_id)

Returns the queued L<Test2::Harness2::Run> with the given id, or
C<undef>.

=item $sch->enqueue($run)

Append C<$run> to the queue. Returns C<$run>.

=item @dropped = $sch->remove_from_queue($run_id)

Drop every queue entry whose C<run_id> matches and return them. Used
by C<finalize_run_if_complete>.

=item $sch->clear_queue

Drop every queue entry. Used by C<service_pre_hard_stop>.

=back

=head2 In-flight counter

=over 4

=item $n = $sch->in_flight_count

Current count of in-flight jobs (collectors + preload spawns
awaiting acknowledgment).

=item $ref = $sch->in_flight_ref

Scalar ref to the in-flight counter. Resources hold this so they can
read live utilization without a per-mutation notification loop.

=item $sch->inc_in_flight / $sch->dec_in_flight

Adjust the counter from the launch path / job-release path.

=item $sch->reset_in_flight_count

Reset to zero. Used by C<service_post_hard_stop>.

=back

=head2 Per-run scheduler table

=over 4

=item $sch->queue_run($run)

Seed the scheduler's per-run bookkeeping (pending job ids, empty
running map, started=0). Called once when a run is accepted.

=item $aref = $sch->pending_for_run($run_id)

Returns the run's pending job-id arrayref.

=item $bool = $sch->is_running($run_id, $job_id)

True when the named job is in the running set for the run.

=item $bool = $sch->started($run_id)

True once the run has launched at least one job.

=item $sch->mark_running($run_id, $job_id)

Move C<$job_id> from pending to running. Sets C<started>.

=item $sch->mark_pending($run_id, $job_id)

Restore C<$job_id> to pending and drop it from running. Used by the
preload-spawn watchdog when an in-flight request times out.

=item $sch->mark_done($run_id, $job_id)

Drop C<$job_id> from running.

=item $sch->skip($run_id, $job_id)

Drop C<$job_id> from pending without ever marking it running. Sets
C<started>.

=item $sch->drop_run($run_id)

Forget the run's scheduler bookkeeping. Called from
C<finalize_run_if_complete>.

=item $bool = $sch->run_complete($run_id)

True when the run has no pending and no running jobs AND has
launched at least one job (so an empty queue at startup is not
treated as complete).

=item $snap = $sch->snapshot($run_id)

Compact snapshot of the run's scheduler entry: C<pending> arrayref,
C<running> arrayref, C<started> flag. Returns C<undef> when the run
is not tracked.

=back

=head2 Tick + dispatch

=over 4

=item $launched = $sch->try_launch_next

Single scheduler tick. Walks the queue, finds the first run not yet
complete, and tries to launch one of its pending jobs. Returns true
when a job was launched (caller should call again to fill any
remaining slots), false when nothing launched.

=item $outcome = $sch->dispatch_pending($run, $job)

Per-job dispatch decision used by C<try_launch_next>. Returns
C<'launched'> when the job was launched (or routed through an
unavailable-action launch) and C<'defer'> otherwise. Encapsulates the
run-aborted short-circuit, preload routing, and resource evaluation.

=item ($decision, $arg) = $sch->evaluate_resources($run, $job)

Walks the global + per-run resources for a job and returns one of
C<('launch', \@use)>, C<('defer')>, C<('skip', $name)>, or
C<('broken', $name)>.

=item $outcome = $sch->handle_broken_resource($run, $job, $name, %opts)

Dispatch for C<('broken')>: routes through skip / fail / abort based
on C<broken_resource_behavior>.

=item $outcome = $sch->launch_unavailable_action($run, $job, $kind, $name, %opts)

Launch a synthetic C<perl -e> skip / fail through the normal
collector path so the on-disk artifacts mirror a real test.

=item $sch->finalize_run_if_complete($run)

Snapshot final results, drop the run from the queue, tear down its
per-run service, and transition the harness to finishing if we're
in C<finish_after_initial_run> mode.

=back

=head2 Inherited

=over 4

=item $h = $sch->harness

Returns the harness reference, or C<undef> when the harness has
gone away. Inherited from L<Test2::Harness2::Role::Subsystem>.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::RunStates>, L<Test2::Harness2::PidIndex>.

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
