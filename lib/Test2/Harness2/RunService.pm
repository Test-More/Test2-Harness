package Test2::Harness2::RunService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX ();

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Run::State;
use Test2::Harness2::TestFile;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <log_name
    <run_id
    <job_id
    <kill_timeout
    <ipcm_info
    <parent_pids
    <harness_name
    <loggers
    <test_loggers
    <collector_grace_secs
    +run
    +run_state
    state
    <resource_services
    +test_jobs
    +completed_job_ids
    +pending_synth_completions
    +emitter
    +artifacts
    watch_pids
    own_pgroup
};

# Default grace window after a collector pid goes away with no
# test_job_completed in hand. Overridable per-RunService via the
# collector_grace_secs attribute.
use constant DEFAULT_COLLECTOR_GRACE_SECS => 10;

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj   { $_[0]->{+RUN} }
sub run_state { $_[0]->{+RUN_STATE} }

# Reservation check on the role uses the log file name, not the bus
# name (which is suffixed with the run_id to guarantee uniqueness
# across runs on the shared IPC bus).
sub service_host_log_name { $_[0]->{+LOG_NAME} }

# Resource-service log files live under the harness's $logdir, not the
# bare $workdir.
sub service_host_logdir { $_[0]->{+LOGDIR} }

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the run service is the
# run-scoped host for its Run, so its own name is reserved in per-run
# scope for this specific run. A global-scoped resource never sees this
# reservation, and other runs never collide with ours.
sub service_host_scope { 'run' }
sub service_host_run   { $_[0]->{+RUN} }

# The run service acts as a subreaper for the run's subtree (tests it
# launches and resource services scoped to this run).
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    my $run = $self->{+RUN} // croak "'run' is a required attribute";
    croak "'run' must be a Test2::Harness2::Run, got " . (blessed($run) || ref($run) || '(scalar)')
        unless blessed($run) && $run->isa('Test2::Harness2::Run');

    $self->{+RUN_ID} //= $run->run_id;

    # logdir defaults to $workdir/logs/ -- mirroring the harness's own
    # default. Callers that pass their own logdir (typically the
    # harness handing through $self->{+LOGDIR}) get that path verbatim.
    $self->{+LOGDIR} //= "$wd/logs";
    my $logdir  = $self->{+LOGDIR};
    my $svc_dir = "$logdir/runs/$self->{+RUN_ID}/services";
    make_path($svc_dir) unless -d $svc_dir;

    $self->{+LOG_NAME}                  //= 'run';
    $self->{+NAME}                      //= "run-$self->{+RUN_ID}";
    $self->{+HARNESS_NAME}              //= 'harness';
    $self->{+JOB_ID}                    //= gen_uuid();
    $self->{+KILL_TIMEOUT}              //= 15;
    $self->{+PARENT_PIDS}               //= [];
    $self->{+STATE}                     //= 'running';
    $self->{+RESOURCE_SERVICES}         //= {};
    $self->{+TEST_JOBS}                 //= {};
    $self->{+COMPLETED_JOB_IDS}         //= {};
    $self->{+PENDING_SYNTH_COMPLETIONS} //= {};
    $self->{+WATCH_PIDS}                //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}                //= 0;
    $self->{+COLLECTOR_GRACE_SECS}      //= DEFAULT_COLLECTOR_GRACE_SECS;
    $self->{+ARTIFACTS}                 //= {};

    # Logger lists default to empty: the caller (typically the harness,
    # via effective_service_loggers / effective_test_loggers) decides
    # what, if anything, gets written to disk. Mirrors the harness's
    # own "caller decides" pattern on its LOGGERS slot.
    $self->{+LOGGERS}      //= [];
    $self->{+TEST_LOGGERS} //= [];

    croak "'loggers' must be an arrayref"
        unless ref($self->{+LOGGERS}) eq 'ARRAY';
    croak "'test_loggers' must be an arrayref"
        unless ref($self->{+TEST_LOGGERS}) eq 'ARRAY';

    # The Run is now an immutable spec; lifecycle state lives on a
    # paired Run::State the run service owns. Construct the State
    # alongside, seed pending with every job_id, and seed per-job
    # results entries with queue-time metadata so downstream consumers
    # (the streamer in particular) can identify every job and order
    # lifecycle events by Time::HiRes stamp without having to cross-
    # reference the jobs array themselves. Entries are filled in
    # further as the job moves through started -> completed.
    my $rstate = $self->{+RUN_STATE} //= Test2::Harness2::Run::State->new(
        run_id     => $self->{+RUN_ID},
        created_at => $run->created_at,
    );
    croak "'run_state' must be a Test2::Harness2::Run::State, got " . (blessed($rstate) || ref($rstate) || '(scalar)')
        unless blessed($rstate) && $rstate->isa('Test2::Harness2::Run::State');

    $rstate->seed_pending(map { $_->job_id } @{$run->jobs})
        unless @{$rstate->pending};

    my $queued_at = time;
    for my $job (@{$run->jobs}) {
        my $jid = $job->job_id;
        my $tf  = $job->test_file;
        $rstate->seed_job_result(
            $jid,
            queued_at => $queued_at,
            job_try   => $job->job_try,
            file      => $tf->absolute,
            abs_file  => $tf->absolute,
            rel_file  => $tf->relative,
        );
    }
}

# IPC::Manager::Role::Service contract (orig_io, pid, set_pid,
# watch_pids, handle_request) and the default request_handler_terminate
# come from Test2::Harness2::Role::Service. Service-specific handlers
# start here.

# Harness-to-RunService IPC: launch a test job under this run. The
# harness has already done scheduling (needed / available / assign);
# we only spawn the Collector and track its pid, so that the test
# process lives inside the run's subtree and the run service can reap
# it, forward its exit status back, and enforce shutdown cascades.
sub request_handler_launch_job {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'run service not accepting launches'}
        if $self->{+STATE} ne 'running';

    for my $required (qw/job_id test_file/) {
        return {ok => 0, error => "'$required' is required"}
            unless defined $payload->{$required};
    }

    my $job_id   = $payload->{job_id};
    my $job_try  = $payload->{job_try} // 0;
    my $run_id   = $payload->{run_id}  // $self->{+RUN_ID};
    my $log_file = $payload->{log_file};
    my $env      = $payload->{env} // {};
    my $auditor  = $payload->{auditor};
    # Per-job logger spec list. Defaults to the RunService's own
    # TEST_LOGGERS (set at spawn time from the run's effective
    # test_loggers list). Callers can override per-launch via the
    # payload -- not used from the standard harness path but kept
    # for targeted launches (e.g. unavailable-action skip /
    # unavailable-action fail). This service no longer injects any
    # hard-coded JSONL / JSON pair -- if the caller wants those, they
    # include the specs (typically with placeholder paths, see below).
    my $payload_loggers = $payload->{loggers} // $self->{+TEST_LOGGERS} // [];
    my $test_file_abs   = $payload->{test_file};
    my $launch_cmd      = $payload->{launch};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless File::Spec->file_name_is_absolute($test_file_abs);

    # The harness's unavailable-action skip / unavailable-action fail
    # paths hand us an explicit launch command (perl -e '...').
    # Default to running the real test file when no override is
    # present. When the launch payload's env carries
    # T2_HARNESS_INCLUDES (forwarded by Test2::Harness2::_launch_job),
    # turn it into -I flags so the child's @INC actually picks the
    # paths up -- the env var alone is not enough since exec(perl ...)
    # starts a fresh interpreter.
    if (!defined $launch_cmd) {
        my @extra_inc;
        if (my $payload_env = $payload->{env}) {
            my $inc = $payload_env->{T2_HARNESS_INCLUDES};
            @extra_inc = grep { length && $_ ne '.' } split /;/, $inc
                if defined $inc && length $inc;
        }
        $launch_cmd = [$^X, (map { "-I$_" } @extra_inc), '-Ilib', $test_file_abs];
    }

    # Default the payload-level log_file only if the caller wants one;
    # loggers are otherwise driven entirely by the payload_loggers
    # specs. Kept for back-compat with callers that pass log_file
    # explicitly.
    $log_file //= undef;

    # Snapshot-style loggers (JSON sidecar) need a 'spec' object to
    # serialize at startup. When the caller did not provide one,
    # synthesize a minimal TestFile from the launch payload's
    # test_file path so the resulting .json includes the relative
    # and absolute test-file paths. Callers that supply their own
    # spec are left alone.
    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    my @logger_specs = map { _maybe_inject_test_file_spec($_, $test_file_spec) } @$payload_loggers;

    my $handle;
    my $spawn_ok = eval {
        require Test2::Harness2::Collector::Test;
        $handle = Test2::Harness2::Collector::Test->spawn(
            launch       => $launch_cmd,
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {T2_FORMATTER => 'Stream2', %$env},
            logdir       => $self->{+LOGDIR},
            run_id       => $run_id,
            job_id       => $job_id,
            job_try      => $job_try,
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $self->{+NAME},
            ipc_run      => $self->{+NAME},
            ipc_harness  => $self->{+HARNESS_NAME},
            kill_timeout => $self->{+KILL_TIMEOUT},
            (defined $auditor ? (auditor => $auditor) : ()),
            loggers => [@logger_specs],
        );
        1;
    };
    my $spawn_err = $@;

    unless ($spawn_ok) {
        return {ok => 0, error => "collector spawn failed: $spawn_err"};
    }

    my $pid = $handle->pid;
    $self->{+TEST_JOBS}->{$pid} = {
        job_id     => $job_id,
        job_try    => $job_try,
        run_id     => $run_id,
        pid        => $pid,
        handle     => $handle,
        log_file   => $log_file,
        started_at => time,
    };

    # NOTE: do not register the collector pid as an IPC::Manager worker.
    # The role's reap_children silently consumes worker-pid exits without
    # calling run_on_pid, so we would never see the exit and the harness
    # would never learn the job completed. Keeping it out of the worker
    # map routes the exit through run_on_pid where we forward it via
    # test_job_completed.
    return {ok => 1, pid => $pid, log_file => $log_file};
}

sub request_handler_status {
    my $self = shift;

    my @services;
    for my $svc (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        push @services => {
            pid           => $svc->{pid},
            name          => $svc->{name},
            service_class => $svc->{service_class},
            log_path      => $svc->{log_path},
            restartable   => $svc->{restartable},
            resource      => $svc->{resource}->resource_name,
        };
    }

    my @jobs;
    for my $job (values %{$self->{+TEST_JOBS} // {}}) {
        push @jobs => {
            pid        => $job->{pid},
            run_id     => $job->{run_id},
            job_id     => $job->{job_id},
            job_try    => $job->{job_try},
            log_file   => $job->{log_file},
            started_at => $job->{started_at},
        };
    }

    return {
        service => {
            name     => $self->{+NAME},
            log_name => $self->{+LOG_NAME},
            pid      => $$,
            job_id   => $self->{+JOB_ID},
            workdir  => $self->{+WORKDIR},
            run_id   => $self->{+RUN_ID},
            state    => $self->{+STATE},
        },
        resource_services => \@services,
        test_jobs         => \@jobs,
    };
}

# Role::Service provides run_on_start. These hooks tack on the
# run-specific extras: run_id in the service_started event and
# bringing up the run's resource services. The initial Run snapshot
# is handled by the JSON logger on the interpose collector (via
# run_mutation events we emit on every state change); the legacy
# RunService-side snapshot writer is gone.
sub service_started_fields {
    my $self = shift;
    return (run_id => $self->{+RUN_ID});
}

sub service_on_start {
    my $self = shift;

    # Stamp the start time on the State so the persisted state.json
    # has it the moment any consumer reads it. Idempotent.
    $self->{+RUN_STATE}->mark_started;

    # Emit run_queued so the JSON logger writes the immutable Run
    # spec to runs/<run_id>/spec.json.zst. Sent before run_mutation
    # so the spec is on disk by the time any state-consumer wakes
    # up; the spec is queue-time-frozen and never changes after.
    $self->_emit_run_log_event(
        kind     => 'run_queued',
        run_data => $self->{+RUN}->TO_JSON,
    );

    # Emit an initial run_mutation so the JSON logger lands a file
    # immediately, even for a run that never mutates during its
    # lifetime (e.g. all jobs skipped due to broken resources).
    $self->_broadcast_run_state;

    # Bring up the run's resource services. The harness has already
    # validated the resource set (needed + non-permanent) before
    # spawning us; we just start whatever is configured.
    my $resources = $self->{+RUN}->resources // [];
    $self->start_resource_services($resources, scope => 'run', run => $self->{+RUN})
        if @$resources;

    return;
}

sub run_on_all {
    my ($self, $activity) = @_;

    # Reap any descendants quickly; IPC::Manager's tick drives
    # run_on_pid for exits, so there's nothing more for us to do here
    # beyond letting the loop roll over.
    return;
}

sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    # Test-collector exit. The authoritative completion message
    # (test_job_completed) now flows through the collector's own
    # TestObserver after the auditor has consumed harness_job_exit
    # and stamped the final verdict into the payload. If that
    # message already arrived, we just clear our tracking entry.
    # Otherwise we arm a grace timer so the watchdog in
    # run_on_interval can synthesize completion if nothing comes
    # in -- collector may have crashed before it got to emit.
    if (my $job = delete $self->{+TEST_JOBS}->{$pid}) {
        my $job_id = $job->{job_id};

        if ($self->{+COMPLETED_JOB_IDS}->{$job_id}) {
            # The collector already told us it was done; the exit
            # we just reaped is the matching post-emit reap.
            return;
        }

        $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id} = {
            %$job,
            pid_gone_at      => time,
            raw_exit_on_reap => $exit,
        };
        return;
    }

    # Resource-service exit (handled by the shared host role).
    # Reparented descendants that aren't one of ours silently fall
    # through.
    $self->handle_resource_service_exit($pid, $exit);

    return;
}

# Collector-side watchdog: if a collector pid disappeared without
# test_job_completed being received, synthesize completion once the
# grace window expires. IPC::Manager drives run_on_interval every
# ~0.2s so the resolution is sub-second even though the grace
# window is seconds-scale.
sub run_on_interval {
    my $self = shift;

    my $pending = $self->{+PENDING_SYNTH_COMPLETIONS} or return;
    return unless keys %$pending;

    my $now   = time;
    my $grace = $self->{+COLLECTOR_GRACE_SECS} // DEFAULT_COLLECTOR_GRACE_SECS;

    for my $job_id (keys %$pending) {
        my $entry = $pending->{$job_id};

        # Did a real test_job_completed arrive during the grace
        # window? Drop the pending synth.
        if ($self->{+COMPLETED_JOB_IDS}->{$job_id}) {
            delete $pending->{$job_id};
            next;
        }

        next if ($now - $entry->{pid_gone_at}) < $grace;

        warn sprintf(
            "RunService: synthesizing test_job_completed for job %s " . "(collector pid %d): no test_job_completed in %ds after pid exit\n",
            $job_id, $entry->{pid} // 0, $grace,
        );

        delete $pending->{$job_id};

        my $raw = $entry->{raw_exit_on_reap};
        $self->_handle_gen_msg_test_job_completed({
            run_id  => $entry->{run_id},
            job_id  => $job_id,
            job_try => $entry->{job_try},
            exit    => $raw,
            synth   => 1,
        });
    }

    return;
}

# Incoming IPC messages from test-job collectors (and their
# observers). IPC::Manager::Role::Service feeds every non-request
# message here after message-handler dispatch has already looked for
# a matching request_handler_*. The harness aggregates its own shadow
# Run by consuming run_state_update messages we produce here.
#
# Dispatch is name-prefixed (_handle_gen_msg_${kind}) so the per-kind
# handlers live in their own namespace and cannot collide with
# unrelated method names. Unknown kinds are silently dropped, same
# as the previous explicit-elsif chain.
sub run_on_general_message {
    my ($self, $msg) = @_;

    my $content = $msg->content;
    my $kind    = ref($content) eq 'HASH' ? $content->{kind} : undef;
    return unless defined $kind;

    my $method = "_handle_gen_msg_$kind";
    return unless $self->can($method);
    return $self->$method($content);
}

sub _handle_gen_msg_test_job_started {
    my ($self, $content) = @_;

    my $job_id = $content->{job_id} // return;

    # Record collector + test pids on our tracking entry so the
    # watchdog (added in a later commit) and any status queries see
    # the live pids the collector reported.
    if (my $info = $self->_job_tracking_by_collector_pid($content->{collector_pid})) {
        $info->{collector_pid}       //= $content->{collector_pid};
        $info->{test_pid}            //= $content->{test_pid};
        $info->{started_at_reported} //= $content->{stamp} // time;
    }

    # Mutate Run state: pending -> running. Guard with an eval so an
    # out-of-order started message (should not happen but: belt +
    # suspenders) doesn't take the service down.
    my $ok  = eval { $self->{+RUN_STATE}->mark_running($job_id); 1 };
    my $err = $@;
    warn "run service could not mark job '$job_id' running: $err" unless $ok;

    my $started_at = $content->{stamp} // time;
    $self->{+RUN_STATE}->seed_job_result($job_id, started_at => $started_at);

    $self->_emit_run_log_event(
        kind     => 'job_started',
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
    );

    $self->_broadcast_run_state;
    return;
}

sub _handle_gen_msg_test_job_diagnosing {
    my ($self, $content) = @_;

    $self->_emit_run_log_event(
        kind     => 'job_diagnosing',
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );
    return;
}

sub _handle_gen_msg_test_job_failing {
    my ($self, $content) = @_;

    $self->_emit_run_log_event(
        kind     => 'job_failing',
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );
    return;
}

sub _handle_gen_msg_test_job_completed {
    my ($self, $content) = @_;

    my $job_id = $content->{job_id} // return;

    # Idempotent guard: the observer-emitted message and the
    # watchdog-synthesized message can race. First one wins; the
    # second is dropped.
    return if $self->{+COMPLETED_JOB_IDS}->{$job_id};
    $self->{+COMPLETED_JOB_IDS}->{$job_id} = 1;
    delete $self->{+PENDING_SYNTH_COMPLETIONS}->{$job_id};

    # Record the authoritative verdict + exit details keyed by
    # job_id so the State snapshot can carry them out to the harness
    # (via run_state_update) and any harness-side IPC consumer that
    # wants per-job pass/fail can read them without touching logs.
    # Merge (not replace) so queue-time seeding and started_at stay.
    my $completed_at = $content->{stamp} // time;
    $self->{+RUN_STATE}->record_job_result(
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

    # Mutate Run state: running -> done. Safe to call even if the job
    # was marked skipped earlier (mark_done croaks; we guard).
    my $ok  = eval { $self->{+RUN_STATE}->mark_done($job_id); 1 };
    my $err = $@;
    warn "run service could not mark job '$job_id' done: $err" unless $ok;

    $self->_emit_run_log_event(
        kind     => 'job_completed',
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
        exit       => $content->{exit},
        codes      => $content->{codes},
        pass       => $content->{pass},
        pass_count => $content->{pass_count},
        fail_count => $content->{fail_count},
    );

    $self->_broadcast_run_state;
    return;
}

sub _handle_gen_msg_collector_artifacts {
    my ($self, $content) = @_;

    $self->_merge_artifacts($content->{loggers} // {});

    # Forward the merged artifact set to the harness so it can fan out
    # to any run-scoped subscribers. The mapping is in-memory only;
    # consumers reading the on-disk archive derive the same map from
    # the file tree (extension -> Logger::<XYZ>).
    $self->_send_to_harness({
        kind      => 'run_artifacts_update',
        run_id    => $self->{+RUN_ID},
        artifacts => {%{$self->{+ARTIFACTS} // {}}},
    });

    $self->_emit_run_log_event(
        kind     => 'job_loggers',
        job_info => {
            run_id  => $content->{run_id},
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
        loggers => $content->{loggers} // {},
    );
    return;
}

sub _merge_artifacts {
    my ($self, $loggers) = @_;

    my $logdir    = $self->{+LOGDIR};
    my $artifacts = $self->{+ARTIFACTS} //= {};

    for my $class (keys %$loggers) {
        for my $meta (@{$loggers->{$class}}) {
            for my $key (keys %$meta) {
                next unless $key =~ /_file\z/;
                my $abs = $meta->{$key};
                next unless defined $abs && length $abs;
                my $rel = File::Spec->abs2rel($abs, $logdir);
                if (exists $artifacts->{$rel} && $artifacts->{$rel} ne $class) {
                    warn "Test2::Harness2::RunService: artifact '$rel' already claimed by $artifacts->{$rel}, ignoring duplicate from $class\n";
                    next;
                }
                $artifacts->{$rel} = $class;
            }
        }
    }

    return;
}

sub _job_tracking_by_collector_pid {
    my ($self, $pid) = @_;
    return undef unless defined $pid;
    return $self->{+TEST_JOBS}->{$pid};
}

# Emit a lifecycle event onto the run service's own emitter (which
# is the collector-interposed STDOUT of the service, i.e. it ends up
# in the run's .jsonl / .json log via the run-service collector's
# loggers).
sub _emit_run_log_event {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;
    $em->emit_event(
        run_id => $self->{+RUN_ID},
        %fields,
    );
    return;
}

# After any mutation to the Run::State: fire a run_mutation event onto
# the run's own emitter (so the JSON logger will overwrite its snapshot)
# and send a run_state_update IPC to the harness carrying the full
# State->TO_JSON payload so the harness's mirror stays in sync.
#
# Full snapshots, not diffs. Simpler, and the payloads are small
# enough that per-mutation replay is not a concern.
sub _broadcast_run_state {
    my $self = shift;

    my $snap = $self->{+RUN_STATE}->TO_JSON;

    $self->_emit_run_log_event(
        kind     => 'run_mutation',
        run_data => $snap,
    );

    $self->_send_to_harness({
        kind     => 'run_state_update',
        run_id   => $self->{+RUN_ID},
        run_data => $snap,
    });

    return;
}

sub _send_to_harness {
    my ($self, $msg) = @_;

    my $ok = eval {
        my $handle = IPC::Manager::Service::Handle->new(
            service_name => $self->{+HARNESS_NAME},
            ipcm_info    => $self->ipcm_info,
        );
        $handle->client->send_message($self->{+HARNESS_NAME}, $msg);
        1;
    };
    warn "RunService could not notify harness: $@" unless $ok;
    return;
}

sub run_should_end {
    my $self = shift;

    return 0 unless $self->{+STATE} eq 'terminating';

    # Wait until every resource service AND every test collector we
    # were tracking has exited before we let the loop unwind.
    return 0 if keys %{$self->{+RESOURCE_SERVICES} // {}};
    return 0 if keys %{$self->{+TEST_JOBS}         // {}};
    return 1;
}

sub run_on_cleanup {
    my $self = shift;

    # Final hard-stop in case we're unwinding without a prior terminate
    # (e.g. our parent died). Drain any remaining resource services and
    # test collectors.
    $self->perform_hard_stop
        if keys %{$self->{+RESOURCE_SERVICES} // {}}
        || keys %{$self->{+TEST_JOBS} // {}};

    for my $res (@{$self->{+RUN}->resources // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

    # Stamp finish time + completed flag on the State so the persisted
    # snapshot reflects the terminal state.
    $self->{+RUN_STATE}->mark_finished;

    # Final run_mutation so the JSON logger's cached snapshot
    # reflects the run's terminal state before the collector shuts
    # down and writes the sidecar file.
    $self->_broadcast_run_state;

    $self->emit_service_event(kind => 'service_stopped');
}

# ----------------------------------------------------------------------
# Shutdown
# ----------------------------------------------------------------------

# Role::Service hooks. The shared escalator in Role::Service drives the
# TERM/KILL loop; these methods only feed and clean up the run-side
# tracking hashes.
sub hard_stop_pids {
    my $self = shift;

    my %pids;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }
    for my $info (values %{$self->{+TEST_JOBS} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    return %pids;
}

# Mid-loop reap hook: as the escalator reaps a pid, drop it from our
# tracking hashes too so run_should_end sees the updated counts on the
# next tick.
sub service_on_reaped {
    my ($self, $pid) = @_;
    delete $self->{+RESOURCE_SERVICES}->{$pid};
    delete $self->{+TEST_JOBS}->{$pid};
    return;
}

# Post-stop cleanup: anything still tracked after the escalator gave up
# has been IGNORE'd (alive after KILL + grace). Drop it so
# run_should_end sees empty maps.
sub service_post_hard_stop {
    my $self = shift;
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+TEST_JOBS}         = {};
    return;
}

# ----------------------------------------------------------------------
# Emission helper
# ----------------------------------------------------------------------

sub emit_service_event {
    my ($self, %fields) = @_;

    my $em = $self->{+EMITTER} or return;    # no emitter in unit tests
    $em->emit_event(
        job_id  => $self->{+JOB_ID},
        run_id  => $self->{+RUN_ID},
        job_try => 0,
        %fields,
    );

    return;
}

# ----------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------

# Take over the current process as a run service. Mirrors the harness
# service's interpose pattern: fork once so the parent becomes the
# run-service collector (with the configured loggers writing the
# run's .jsonl and .json sidecars via the logger role's path rules),
# and the child continues as the actual run-service event loop with
# its STDOUT/STDERR piped through the collector.
sub start {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};

    my $caller_pid = $$;
    $args{parent_pids} //= [$caller_pid];

    my $self = $class->new(%args);

    my $loggers = $self->{+LOGGERS};

    # Everything the interpose child needs after the pipes are wired up.
    my $run_service = sub {
        # The EventEmitter wraps STDOUT (and, when the interpose
        # collector advertises separate pipes via T2_HARNESS2_PIPE_COUNT,
        # STDERR) for the sync marker. We use the process-wide cached
        # instance so anything else in this service that emits shares
        # one wrapper around the real FDs.
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

        my $self_ref = $self;
        local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    # is_run => 1 marks the loggers as belonging to the run-service
    # collector so the role's path derivation lands the .jsonl /
    # .json under runs/<run_id>/ rather than runs/<run_id>/services/.
    require Test2::Harness2::Collector::Service;
    Test2::Harness2::Collector::Service->interpose(
        ipcm_info    => $self->ipcm_info,
        ipc_parent   => $self->{+HARNESS_NAME},
        ipc_run      => $self->{+NAME},
        ipc_harness  => $self->{+HARNESS_NAME},
        bus_id       => "collector:" . $self->{+NAME},
        is_run       => 1,
        logdir       => $self->{+LOGDIR},
        service_name => $self->{+RUN_ID},
        run_id       => $self->{+RUN_ID},
        loggers      => $loggers,
        parser       => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids  => [$caller_pid],
        kill_timeout => $self->{+KILL_TIMEOUT},
    );

    # Reached only in the interpose child; the interpose parent becomes
    # the collector and exits from _interpose_parent before returning.
    $run_service->();
}

# Fork a run service from the calling process (typically the harness).
# Shares the caller's ipcm_info so both services are on the same bus.
# Returns the child pid in the parent; the child never returns from
# this call.
sub spawn {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};
    croak "'run' is required"       unless defined $args{run};

    my $parent_pid = $$;
    $args{parent_pids} //= [$parent_pid];

    my $pid = fork // die "fork: $!";

    # Parent: just return the pid. Ready-state is signalled via
    # service_started appearing on the IPC bus, but callers that
    # don't need the signal can fire-and-forget.
    return $pid if $pid;

    # Child: take over the process and run the service loop.
    $class->start(%args);
    POSIX::_exit(255);    # start() should never return
}

# Auto-inject 'spec' for Logger::JSON when the caller did not
# provide one. Without a spec the snapshot file is written with
# only exit/pass and no identifying fields; injecting a TestFile
# here gives the .json the file / absolute / relative paths the
# consumer expects. Blessed instances pass through untouched.
sub _maybe_inject_test_file_spec {
    my ($spec, $test_file_spec) = @_;

    return $spec if blessed($spec);
    return $spec unless $test_file_spec;

    my $class = ref($spec) eq 'ARRAY' ? $spec->[0] : $spec;
    return $spec unless defined $class && !ref($class);
    return $spec unless $class eq 'Test2::Harness2::Collector::Logger::JSON';

    if (ref($spec) eq 'ARRAY') {
        my %args = @{$spec}[1 .. $#$spec];
        return $spec if exists $args{spec};
        $args{spec} = $test_file_spec;
        return [$class, %args];
    }

    # Bare class-name spec: upgrade to [$class, spec => $tf].
    return [$class, spec => $test_file_spec];
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::RunService - Per-run supervisor service forked by the
harness for every test run.

=head1 DESCRIPTION

Every time L<Test2::Harness2> accepts a run for launch it forks one of
these as a child process. The run service exists for the lifetime of
the run and has two jobs:

=over 4

=item * Host the run's resource services

Per-run resources (those attached to C<< $run->resources >>) have their
C<service_*> methods invoked here, so any subprocess a resource spawns
is a grandchild of the harness and a direct child of the run service.
The process tree mirrors the ownership model: per-run services live
under their run, not under the harness.

=item * Produce a collected per-run log

Its stdout and stderr are piped through the standard collector with
loggers attached, so every run has a C<runs/E<lt>run_idE<gt>/services/E<lt>nameE<gt>.jsonl>
file that records C<service_started>, C<service_stopped>, and any
diagnostic output the run service or its children emit.

=back

The run service is started even when the run has no resources attached
-- the per-run log is useful on its own, and the consistent shape means
downstream tooling doesn't have to special-case runs with no resources.

Scheduling stays in L<Test2::Harness2> itself; the run service does not
make launch decisions.

=head1 ATTRIBUTES

=over 4

=item workdir (required)

Working directory for the run (the same one the harness uses).

=item run (required)

The L<Test2::Harness2::Run> being supervised.

=item run_id

Defaulted from C<< $run->run_id >>.

=item name

Service name. Defaults to C<'run'>; the name determines the log file:
C<< <workdir>/runs/<run_id>/services/<name>.jsonl >>. Also reserved in
this run's per-run service-name scope so a resource service can't
collide with it.

=item ipcm_info (required for spawn/start)

L<IPC::Manager> bus info. Typically inherited from the harness.

=item parent_pids

Pids the service should self-terminate with. Defaults to the caller
(harness) pid.

=item kill_timeout

Seconds to wait between TERM and KILL during shutdown. Default C<15>.

=back

=head1 METHODS

=over 4

=item $pid = Test2::Harness2::RunService->spawn(%args)

Fork from the caller and launch a run service child. Returns the pid
in the parent; the child never returns.

=item Test2::Harness2::RunService->start(%args)

Run the service loop in the current process (after the harness has
already forked). Does not return.

=item $rv = $svc->request_handler_terminate

IPC handler: initiate a hard stop. TERMs tracked resource services
(escalating to KILL after C<kill_timeout> seconds) and exits.

=item $rv = $svc->request_handler_status

IPC handler: snapshot of the run service state including every tracked
resource service.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
