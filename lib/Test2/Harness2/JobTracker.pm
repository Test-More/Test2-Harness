package Test2::Harness2::JobTracker;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use Time::HiRes qw/time/;

use Test2::Harness2::Run::State;

# Fallback used when the harness backref has gone away (deferred
# timer, drained queue) so check_synth_completions still has a
# coherent grace window to compare against. The live default lives
# on Test2::Harness2 and is what wins under normal operation.
use constant DEFAULT_COLLECTOR_GRACE_SECS => 10;

use Object::HashBase qw{
    +running_jobs
    +pending_synth_completions
    +harness
    +run_states
    +pid_index
    +scheduler
    +broadcaster
};

use Role::Tiny::With;
with 'Test2::Harness2::Role::Subsystem';

sub init {
    my $self = shift;

    croak "'harness' is required"     unless $self->{+HARNESS};
    croak "'run_states' is required"  unless $self->{+RUN_STATES};
    croak "'pid_index' is required"   unless $self->{+PID_INDEX};
    croak "'scheduler' is required"   unless $self->{+SCHEDULER};
    croak "'broadcaster' is required" unless $self->{+BROADCASTER};

    $self->{+RUNNING_JOBS}              //= {};
    $self->{+PENDING_SYNTH_COMPLETIONS} //= {};

    return;
}

#-------------------------------------------------------------------
# Direct slot accessors -- callers (harness shims, hard-stop path,
# request_handler_status) need to look at the live RUNNING_JOBS map
# and the pending-synth queue without going through method calls
# for every read.
#-------------------------------------------------------------------

sub running_jobs              { $_[0]->{+RUNNING_JOBS} }
sub pending_synth_completions { $_[0]->{+PENDING_SYNTH_COMPLETIONS} }

# Wholesale reset hook for service_post_hard_stop: drop every tracked
# entry. The caller is responsible for whatever resource teardown
# needed to happen first.
sub clear_running_jobs { $_[0]->{+RUNNING_JOBS} = {}; return }

# Drop and return a single running-job entry. Used by the harness's
# preload-spawn rollback path (the placeholder must come out without
# also signaling a release, because the limiters were never assigned
# in the first place) and by the watchdog. Returns the dropped entry
# or undef.
sub take_running_job {
    my ($self, $job_id) = @_;
    return delete $self->{+RUNNING_JOBS}->{$job_id};
}

# Used by the launch glue on the harness side: install the freshly-
# spawned (or preload-placeholder) job's tracking entry.
sub set_running_job {
    my ($self, $job_id, $entry) = @_;
    $self->{+RUNNING_JOBS}->{$job_id} = $entry;
    return $entry;
}

#-------------------------------------------------------------------
# Collector lifecycle reflection. The harness's own collector picks
# these up via the standard pipeline and writes harness_collector_*
# rows into services/harness/events.jsonl.zst. Top-level facet (NOT
# nested under facet_data.harness) so the Log iterator's depth-first
# walk can detect them.
#-------------------------------------------------------------------

sub handle_collector_start {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->_harness_emitter or return;
    $em->emit_raw({
        facet_data => {
            harness_collector_start => {%$content},
        },
    });

    return;
}

sub handle_collector_end {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->_harness_emitter or return;
    $em->emit_raw({
        facet_data => {
            harness_collector_end => {%$content},
        },
    });

    return;
}

# Resolve the harness emitter via the harness backref. The harness
# stores it under the 'emitter' HashBase slot; reach for that by
# bare string so JobTracker stays decoupled from Test2::Harness2's
# constant namespace.
sub _harness_emitter {
    my $self = shift;
    my $h = $self->harness or return undef;
    return $h->{emitter};
}

#-------------------------------------------------------------------
# Per-job lifecycle handlers. These mutate run state in-process, emit
# a run-level lifecycle event onto the harness's own service event
# stream, and broadcast the new state snapshot to subscribed peers.
# Per-run side state (first-fail latch, completed-job idempotency
# guard, per-job result snapshots that feed the eventual aggregate
# verdict) lives on RunStates->flags($run_id) so it stays scoped to
# the right run when multiple runs are active.
#-------------------------------------------------------------------

sub handle_test_job_started {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    # Preload-routed jobs landed a placeholder running-job entry at
    # _spawn_via_preload time; the auditor's collector_pid is the
    # first concrete pid we see for the job. Fill in pid + register
    # in the pid index so the rest of the reap / watchdog plumbing
    # sees the entry the same way it does for direct-spawn jobs.
    # Drop the matching pending-spawn-request row on the harness so
    # the watchdog forgets about it.
    my $cur = $self->{+RUNNING_JOBS}->{$job_id};
    if ($cur && $cur->{awaiting_preload_pid}) {
        my $cpid = $content->{collector_pid} // $content->{pid};
        if (defined $cpid) {
            $cur->{pid} = $cpid;
            delete $cur->{awaiting_preload_pid};
            $self->{+PID_INDEX}->register(
                $run_id, $cpid,
                kind       => 'collector',
                job_id     => $job_id,
                job_try    => $content->{job_try},
                started_at => $content->{stamp} // time,
            );
        }
        if (my $h = $self->harness) {
            # Pending preload-spawn rows live on the preload router
            # subsystem (its PENDING_SPAWN_REQUESTS HashBase slot).
            # Reach for the bare key so JobTracker stays decoupled
            # from PreloadRouter's constant namespace. `can` so test
            # fixtures that don't wire a router still work.
            if ($h->can('preload_router')) {
                if (my $router = $h->preload_router) {
                    delete $router->{pending_spawn_requests}->{"$run_id\0$job_id"};
                }
            }
        }
    }

    my $rstate = $self->{+RUN_STATES}->state($run_id);
    $rstate = $self->{+RUN_STATES}->set_state(
        $run_id, Test2::Harness2::Run::State->new(run_id => $run_id),
    ) unless $rstate;

    my $started_at = $content->{stamp} // time;

    # pending -> running. Out-of-order or duplicate started messages
    # are tolerated; mark_running is idempotent against running/done.
    my $ok  = eval { $rstate->mark_running($job_id); 1 };
    my $err = $@;
    warn "Test2::Harness2: could not mark job '$job_id' running for run '$run_id': $err"
        unless $ok;

    $rstate->seed_job_result($job_id, started_at => $started_at);

    if (my $h = $self->harness) {
        $h->emit_service_event(
            kind     => 'job_started',
            stamp    => $started_at,
            run_id   => $run_id,
            job_info => {
                run_id  => $run_id,
                job_id  => $job_id,
                job_try => $content->{job_try},
            },
        );
    }

    $self->{+BROADCASTER}->broadcast_run_state($run_id);
    return;
}

sub handle_test_job_diagnosing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $h = $self->harness or return;
    my $run_id = $content->{run_id} // return;
    $h->emit_service_event(
        kind     => 'job_diagnosing',
        stamp    => time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );
    return;
}

sub handle_test_job_failing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $h = $self->harness or return;
    my $run_id = $content->{run_id} // return;
    $h->emit_service_event(
        kind     => 'job_failing',
        stamp    => time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );

    my $flags = $self->{+RUN_STATES}->flags($run_id);
    unless ($flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $h->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    return;
}

sub handle_test_job_completed {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    my $run_states = $self->{+RUN_STATES};
    my $flags      = $run_states->flags($run_id);

    # Idempotent against the auditor + watchdog race: first wins.
    return if $flags->{completed_job_ids}{$job_id};
    $flags->{completed_job_ids}{$job_id} = 1;

    # Snapshot the full payload so the run-aggregate path can build
    # without disk reads.
    $flags->{completed_job_states}{$job_id} = {%$content};

    my $h = $self->harness;
    if ($h && !$content->{pass} && !$flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $h->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    my $rstate = $run_states->state($run_id);
    $rstate = $run_states->set_state(
        $run_id, Test2::Harness2::Run::State->new(run_id => $run_id),
    ) unless $rstate;

    my $completed_at = $content->{stamp} // time;
    $rstate->record_job_result(
        $job_id,
        pass       => $content->{pass} ? 1 : 0,
        exit       => $content->{exit},
        codes      => $content->{codes},
        pass_count => $content->{pass_count},
        fail_count => $content->{fail_count},
        ($content->{times}              ? (times       => $content->{times})       : ()),
        ($content->{child_times}        ? (child_times => $content->{child_times}) : ()),
        (defined $content->{child_wall} ? (child_wall  => $content->{child_wall})  : ()),
        stamp        => $completed_at,
        completed_at => $completed_at,
    );

    my $ok  = eval { $rstate->mark_done($job_id); 1 };
    my $err = $@;
    warn "Test2::Harness2: could not mark job '$job_id' done for run '$run_id': $err"
        unless $ok;

    if ($h) {
        $h->emit_service_event(
            kind     => 'job_completed',
            stamp    => $content->{completed_at} // time,
            run_id   => $run_id,
            job_info => {
                run_id  => $run_id,
                job_id  => $job_id,
                job_try => $content->{job_try},
            },
            pass => $content->{pass},
        );
    }

    $self->{+BROADCASTER}->broadcast_run_state($run_id);
    return;
}

#-------------------------------------------------------------------
# Terminal run_completed + collector_report two-facet event emitted
# from the harness's own emitter. Built from per-job state accumulated
# in RUN_FLAGS as test_job_completed messages came in. The renderer's
# harness_run_end synthesizer reads pass/fail counts off the
# collector_report facet.
#-------------------------------------------------------------------

sub emit_run_completed {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $flags = $self->{+RUN_STATES}->flags_peek($run_id) or return;
    return if $flags->{run_completed_emitted}++;

    my $em = $self->_harness_emitter or return;

    my $now    = time;
    my $report = $self->build_collector_report($run, $now);

    # Two-facet event: harness.run_completed (state-flip announcement)
    # + top-level collector_report (data the renderer consumes for
    # the aggregate verdict). emit_raw -- not emit_event -- so
    # collector_report lands at the top of facet_data, not nested
    # under harness.
    $em->emit_raw({
        facet_data => {
            harness => {
                run_id        => $run_id,
                run_completed => {
                    run_id => $run_id,
                    stamp  => $now,
                },
            },
            collector_report => $report,
        },
    });

    return;
}

# Walk RUN_FLAGS->{$run_id}{completed_job_states} (per-job state
# hashes captured at test_job_completed time) and assemble the
# run-level aggregate the renderer summarizes.
sub build_collector_report {
    my ($self, $run, $now) = @_;
    $now //= time;

    my $run_id = $run->run_id;
    my $flags  = $self->{+RUN_STATES}->flags($run_id);
    my $states = $flags->{completed_job_states} // {};

    my %jobs_by_id;
    my ($passed, $failed, $aborted) = (0, 0, 0);
    for my $jid (keys %$states) {
        my $st = $states->{$jid} // {};
        my $entry = $self->_collector_report_job_entry($run, $jid, $st);
        $jobs_by_id{$jid} = $entry;
        if ($entry->{pass}) {
            $passed++;
        }
        else {
            $failed++;
            $aborted++ if $st->{synth};
        }
    }

    my @ordered = $self->_order_collector_report_jobs($run, \%jobs_by_id);

    return {
        pass         => $flags->{pass} ? 1 : 0,
        started_at   => $flags->{started_at},
        ended_at     => $flags->{ended_at} // $now,
        total_jobs   => scalar @ordered,
        passed_jobs  => $passed,
        failed_jobs  => $failed,
        aborted_jobs => $aborted,
        jobs         => \@ordered,
    };
}

# Build one per-job entry for build_collector_report. Resolves the
# test-file path from the Run's queue-time job spec when the per-job
# state did not carry one.
sub _collector_report_job_entry {
    my ($self, $run, $jid, $st) = @_;

    my $file = $st->{file};
    if (!defined $file) {
        for my $job (@{$run->jobs}) {
            next unless $job->job_id eq $jid;
            my $tf = $job->test_file;
            $file = $tf->absolute if $tf;
            last;
        }
    }

    my $tries = defined($st->{job_try}) ? $st->{job_try} : 1;
    return {
        job_id   => $jid,
        file     => $file,
        pass     => $st->{pass} ? 1 : 0,
        tries    => $tries,
        subtests => [@{$st->{subtests} // []}],
    };
}

# Stable ordering for the collector_report jobs array: jobs from the
# Run's queue-time spec come first in spec order; any remaining ids
# are appended in sort order so the array stays deterministic.
sub _order_collector_report_jobs {
    my ($self, $run, $jobs_by_id) = @_;

    my @ordered;
    my %placed;
    for my $job (@{$run->jobs}) {
        my $jid = $job->job_id;
        next unless exists $jobs_by_id->{$jid};
        push @ordered, $jobs_by_id->{$jid};
        $placed{$jid} = 1;
    }
    for my $jid (sort keys %$jobs_by_id) {
        next if $placed{$jid};
        push @ordered, $jobs_by_id->{$jid};
    }

    return @ordered;
}

# Build the "final" snapshot stashed into RunStates->completed so
# callers can query pass/fail via IPC after a run ends but before
# the harness itself exits. Aggregate pass is true when every job
# that reported a result passed; skipped jobs have no result entry
# and therefore do not fail the aggregate.
sub snapshot_run_results {
    my ($self, $run) = @_;

    my $rstate   = $self->{+RUN_STATES}->state($run->run_id);
    my $results  = ($rstate && $rstate->results) // {};
    my $all_pass = 1;
    for my $jid (keys %$results) {
        # Entries without completed_at are queue-time or started-time
        # seeds (jobs that never finished or were skipped). Only
        # completed jobs contribute to the aggregate verdict.
        next          unless defined $results->{$jid}{completed_at};
        $all_pass = 0 unless $results->{$jid}{pass};
    }

    return {
        run_id  => $run->run_id,
        state   => 'complete',
        pass    => $all_pass ? 1 : 0,
        results => {%$results},
        done    => $rstate ? [@{$rstate->done}] : [],
    };
}

#-------------------------------------------------------------------
# Per-job release. Look up the job's tracking entry for its assigned
# resources, release them, drop the entry, and tell the scheduler the
# job is done. The Run mirror's done list is filled in independently
# from broadcast_run_state.
#-------------------------------------------------------------------

sub handle_job_release {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $job_id = $content->{job_id};
    return unless defined $job_id;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;
    $self->{+SCHEDULER}->dec_in_flight;

    my $run_id = $cur->{run}->run_id;
    $self->{+PID_INDEX}->forget($run_id, $cur->{pid}) if $cur->{pid};
    $self->{+SCHEDULER}->mark_done($run_id, $job_id);
    $self->release_job_resources($cur);

    # The job that just finished may have been the last one for
    # its run; check from the scheduler's own perspective.
    $self->{+SCHEDULER}->finalize_run_if_complete($cur->{run});
    return;
}

sub release_job_resources {
    my ($self, $cur) = @_;

    my $assigned = $cur->{assigned_resources} or return;
    my $id       = $cur->{assign_id};

    for my $res (@$assigned) {
        my $ok  = eval { $res->release(id => $id, job => $cur->{job}); 1 };
        my $err = $@;
        warn "failed to release resource '" . $res->resource_name . "': $err"
            unless $ok;
    }

    return;
}

#-------------------------------------------------------------------
# Test-collector exit. The harness owns the collector since Stage 5
# of the RunService flatten, so this is the normal reap site. If
# test_job_completed arrived first, just clear the per-run pid index;
# otherwise arm a synth-completion grace entry so check_synth_completions
# can synthesize completion when the auditor never gets to speak.
# Returns true if handled.
#-------------------------------------------------------------------

sub handle_collector_exit {
    my ($self, $pid, $exit) = @_;

    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        my $run    = $cur->{run};
        my $run_id = $run->run_id;
        my $flags  = $self->{+RUN_STATES}->flags_peek($run_id);

        if ($flags && $flags->{completed_job_ids}{$job_id}) {
            $self->{+PID_INDEX}->forget($run_id, $pid);
            return 1;
        }

        # Keep RUNNING_JOBS in place: a real test_job_completed inside
        # the grace window cancels the synth, and the watchdog reuses
        # this entry to synthesize completion + cleanup if it expires.
        $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id} = {
            run_id           => $run_id,
            job_id           => $job_id,
            job_try          => $cur->{job} ? $cur->{job}->job_try : undef,
            pid              => $pid,
            pid_gone_at      => time,
            raw_exit_on_reap => $exit,
        };

        return 1;
    }
    return 0;
}

# Collector-side watchdog: if a collector pid disappeared without
# test_job_completed being received, synthesize completion once the
# grace window expires. IPC::Manager drives run_on_interval roughly
# every 0.2s so the resolution is sub-second even though the grace
# window is seconds-scale.
sub check_synth_completions {
    my $self = shift;

    my $pending = $self->{+PENDING_SYNTH_COMPLETIONS};
    return unless $pending && keys %$pending;

    my $h = $self->harness;
    # 'collector_grace_secs' is the harness's HashBase slot name;
    # reach for it by bare string so JobTracker stays decoupled from
    # Test2::Harness2's constant namespace.
    my $grace = ($h ? $h->{collector_grace_secs} : undef)
        // DEFAULT_COLLECTOR_GRACE_SECS;
    my $now = time;

    for my $job_id (keys %$pending) {
        my $entry  = $pending->{$job_id};
        my $run_id = $entry->{run_id};

        # A real test_job_completed arrived inside the grace window
        # -- drop the pending synth.
        my $flags = $self->{+RUN_STATES}->flags_peek($run_id);
        if ($flags && $flags->{completed_job_ids}{$job_id}) {
            delete $pending->{$job_id};
            next;
        }

        next if ($now - $entry->{pid_gone_at}) < $grace;

        warn sprintf(
            "Test2::Harness2: synthesizing test_job_completed for job %s (collector pid %d): no test_job_completed in %ds after pid exit\n",
            $job_id, $entry->{pid} // 0, $grace,
        );

        delete $pending->{$job_id};

        my $raw = $entry->{raw_exit_on_reap};

        # Reuse the normal completion handler so Run::State,
        # RUN_FLAGS, run_failing latching, and the collector_report
        # aggregate all see the synthesized entry. pass=0 + zero counts
        # so the renderer surface can distinguish "synthesized fail"
        # from "real fail with known counts".
        $self->handle_test_job_completed({
            run_id     => $run_id,
            job_id     => $job_id,
            job_try    => $entry->{job_try},
            exit       => $raw,
            pass       => 0,
            pass_count => 0,
            fail_count => 0,
            stamp      => time,
            synth      => 1,
        });

        # The collector died without sending job_release, so the
        # release / scheduler cleanup that handle_job_release normally
        # does has to fire here too.
        $self->synth_release_orphan_job($run_id, $job_id, $entry->{pid});
    }

    return;
}

# Counterpart to handle_job_release for the watchdog path: when the
# auditor never got a chance to send job_release, release the
# resources, drop the RUNNING_JOBS entry, mark the scheduler done,
# and trigger run-finalization here.
sub synth_release_orphan_job {
    my ($self, $run_id, $job_id, $pid) = @_;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;
    $self->{+SCHEDULER}->dec_in_flight;

    $self->{+PID_INDEX}->forget($run_id, $pid) if $pid;
    $self->release_job_resources($cur);
    $self->{+SCHEDULER}->mark_done($run_id, $job_id);
    $self->{+SCHEDULER}->finalize_run_if_complete($cur->{run}) if $cur->{run};
    return;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::JobTracker - Per-job lifecycle bookkeeping for the harness.

=head1 DESCRIPTION

The job tracker owns the harness's C<RUNNING_JOBS> map and the
C<PENDING_SYNTH_COMPLETIONS> watchdog queue, plus the per-job lifecycle
handlers that mutate run state in-process when an auditor's
C<test_job_*> message arrives.

The harness constructs one job tracker during its own C<init> and holds
a strong reference to it. The job tracker holds a weakened backref to
the harness via L<Test2::Harness2::Role::Subsystem> for launch glue,
plus direct (strong) references to L<Test2::Harness2::RunStates>,
L<Test2::Harness2::PidIndex>, L<Test2::Harness2::Scheduler>, and
L<Test2::Harness2::StateBroadcaster>.

The job tracker:

=over 4

=item *

Reflects collector_start / collector_end IPC events into the harness's
own outgoing event stream so the Log iterator can descend into a run's
or global service's events.jsonl.

=item *

Owns the C<test_job_started> / C<test_job_diagnosing> / C<test_job_failing>
/ C<test_job_completed> handlers that mutate Run::State, latch run-level
pass/fail flags, emit run-level lifecycle events, and broadcast the new
state snapshot to subscribers.

=item *

Owns the per-job C<job_release> path: drop the tracking entry, release
assigned resources, tell the scheduler the job is done, and ask the
scheduler to finalize the run if this was the last outstanding job.

=item *

Owns the collector-exit + synth-completion watchdog: if a collector
pid disappears without a matching C<test_job_completed>, arm a
pending-synth entry; if the grace window expires before the message
arrives, synthesize a failed completion so Run::State, the
collector_report aggregate, and the renderer all see a coherent
record.

=back

=head1 METHODS

=head2 Slot accessors

=over 4

=item $href = $jt->running_jobs

Returns the live C<RUNNING_JOBS> map (job_id => entry hashref).

=item $href = $jt->pending_synth_completions

Returns the live pending-synth queue keyed by job_id.

=item $entry = $jt->set_running_job($job_id, $entry)

Install the freshly-spawned (or preload-placeholder) job's tracking
entry. Used by the harness's launch glue.

=item $entry = $jt->take_running_job($job_id)

Drop and return a single running-job entry. Used by the harness's
preload-spawn rollback path and by the watchdog.

=item $jt->clear_running_jobs

Drop every tracked entry. Used by the harness's hard-stop path.

=back

=head2 Collector reflection

=over 4

=item $jt->handle_collector_start($content)

Reflect a C<collector_start> IPC into the harness's outgoing event
stream as a top-level C<harness_collector_start> facet. Silent no-op
when the harness has no emitter (unit-test path).

=item $jt->handle_collector_end($content)

Counterpart for C<collector_end>.

=back

=head2 Per-job lifecycle

=over 4

=item $jt->handle_test_job_started($content)

Mark the job running in Run::State, fill in the collector pid for
preload-routed placeholders, seed the per-job result, emit a
C<job_started> service event, and broadcast the new state snapshot.

=item $jt->handle_test_job_diagnosing($content)

Emit a C<job_diagnosing> service event.

=item $jt->handle_test_job_failing($content)

Emit a C<job_failing> service event and latch a one-time C<run_failing>
when this is the first failing job for the run.

=item $jt->handle_test_job_completed($content)

Record per-job result, mark the job done in Run::State, latch
C<run_failing> when the job failed, emit C<job_completed>, and
broadcast the new state snapshot. Idempotent against the
auditor + watchdog race (first-wins per job).

=item $jt->emit_run_completed($run)

Emit the terminal C<run_completed> + C<collector_report> two-facet
event. Idempotent per run.

=item $report = $jt->build_collector_report($run, $now)

Build the C<collector_report> aggregate from per-job state captured
in RunStates flags.

=item $snap = $jt->snapshot_run_results($run)

Build the terminal snapshot stashed into RunStates's completed-runs
table so post-run IPC callers can query pass/fail.

=back

=head2 Release + watchdog

=over 4

=item $jt->handle_job_release($content)

Per-job release: drop the tracking entry, release assigned resources,
mark the scheduler done, and ask the scheduler to finalize the run if
this was the last outstanding job.

=item $jt->release_job_resources($entry)

Release every resource assigned to the supplied running-job entry.
Used by C<handle_job_release> and by the watchdog.

=item $bool = $jt->handle_collector_exit($pid, $exit)

Test-collector reap. If C<test_job_completed> already arrived, clear
the pid index entry and return true. Otherwise arm a
pending-synth-completion entry and return true. Returns false when
C<$pid> does not map to a tracked collector (the harness's
C<run_on_pid> then falls through to other handlers).

=item $jt->check_synth_completions

Walk the pending-synth queue, drop entries whose
C<test_job_completed> arrived during the grace window, and synthesize
a failed completion for any entry past the grace window. Called from
the harness's C<run_on_interval> once per tick.

=item $jt->synth_release_orphan_job($run_id, $job_id, $pid)

Counterpart to C<handle_job_release> for the watchdog path.

=back

=head2 Inherited

=over 4

=item $h = $jt->harness

Returns the harness reference, or C<undef> when the harness has gone
away. Inherited from L<Test2::Harness2::Role::Subsystem>.

=back

=head1 SEE ALSO

L<Test2::Harness2>, L<Test2::Harness2::Role::Subsystem>,
L<Test2::Harness2::RunStates>, L<Test2::Harness2::PidIndex>,
L<Test2::Harness2::Scheduler>, L<Test2::Harness2::StateBroadcaster>.

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
