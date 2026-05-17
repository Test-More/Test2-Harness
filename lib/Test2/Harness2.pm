package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/load_module parse_exit tinysleep/;
use Test2::Harness2::Util::IPC qw/ipc_default_spawn_args/;
use Test2::Harness2::Util::JSON qw/encode_json/;
use POSIX ();

use Atomic::Pipe;
use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::PidIndex;
use Test2::Harness2::SpawnGateway;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Run;
use Test2::Harness2::Run::State;
use Test2::Harness2::TestFile;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <ipc_parent
    <job_id
    <test_auditor
    <kill_timeout
    <parent_pids
    <jump_to
    <resources
    <broken_resource_behavior
    <hash_seed
    state
    +queue
    +run_states
    +scheduler
    +running_jobs
    +in_flight_count
    <resource_services
    <pid_index
    <spawn_gateway
    +run_flags
    <collector_grace_secs
    +pending_synth_completions
    +pending_spawn_requests
    +pending_preload_spawns
    +resources_awaiting_preload
    +known_preload_names
    <preload_spawn_timeout_secs
    <preload_service_spawn_timeout_secs
    +completed_runs
    +finish_after_initial_run
    +emitter
    +subscribers
    +subscriber_retry
    +run_ord_counter
    watch_pids
    own_pgroup
};

# Sentinel run_id key for processes that aren't bound to a particular
# run. The canonical definition lives in Test2::Harness2::PidIndex; this
# constant is re-exported here for legacy in-tree callers.
use constant RUN_PIDS_GLOBAL_KEY => Test2::Harness2::PidIndex::RUN_PIDS_GLOBAL_KEY();

# Valid values for broken_resource_behavior: what the scheduler does
# when a job needs a resource that has been flipped to
# permanent_broken. All three paths route the job through a real
# Collector launch so the on-disk artifacts match a real test's --
# see _launch_unavailable_action_job.
#
#   skip  - launch `perl -e 'use Test2::V0; skip_all ...'` so the
#           job's log looks like a regular test that called skip_all.
#   fail  - launch `perl -e 'die ...'` so the job's log looks like a
#           regular test that failed with an uncaught exception
#           (exit 255 with the message on stderr).
#   abort - same as fail for THIS job plus every remaining pending
#           job in the same run, one at a time as the job limiter
#           frees slots; the run closes out once they all complete.
use constant BROKEN_BEHAVIORS     => {map { $_ => 1 } qw/skip fail abort/};
use constant SUBSCRIBER_RETRY_CAP => 1024;

# Grace window applied when a collector pid exits without a prior
# test_job_completed. The IPC::Manager loop drives run_on_interval
# every ~0.2s so the resolution is sub-second; the window itself is
# seconds-scale so a slow auditor finishing its emit gets a fair
# chance to land before the harness synthesizes a fail.
use constant DEFAULT_COLLECTOR_GRACE_SECS => 10;

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the harness is the global
# host, so its scope is 'global' and no Run is bound to it.
sub service_host_scope { 'global' }
sub service_host_run   { undef }

# Resource-service log files live under the harness's logdir
# ($workdir/logs/ by default), not directly under $workdir.
sub service_host_logdir { $_[0]->{+LOGDIR} }

# The harness service acts as a subreaper so reparented descendants
# (double-forked tests, tests that setsid + exit their parent) still
# land inside perform_hard_stop's reach on shutdown.
sub become_sub_reaper { 1 }

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;

    $self->_init_logdir($wd);

    $self->_init_default_slots;

    $self->{+BROKEN_RESOURCE_BEHAVIOR} //= 'skip';
    croak "invalid broken_resource_behavior '$self->{+BROKEN_RESOURCE_BEHAVIOR}' (want skip, fail, or abort)"
        unless BROKEN_BEHAVIORS->{$self->{+BROKEN_RESOURCE_BEHAVIOR}};

    $self->_init_resources;

    $self->_strip_legacy_logger_slots;

    # The test auditor default is still set here: a run-complete
    # pass/fail verdict is useless without it.
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
}

# Resolve, validate, and create the logdir (and its services/
# subdirectory) under the harness workdir. Sets +LOGDIR in place.
sub _init_logdir {
    my $self = shift;
    my ($wd) = @_;

    # logdir defaults to 'logs' under the workdir. A caller-supplied
    # relative path is resolved under the workdir; an absolute path is
    # used verbatim (File::Spec handles non-unix absolute shapes like
    # 'C:\...' and UNC paths, so we do not just check for a leading /).
    # An existing empty directory is accepted -- only a non-empty
    # logdir clobbers prior output and is refused.
    my $logdir = $self->{+LOGDIR} // 'logs';
    $logdir = File::Spec->catdir($wd, $logdir)
        unless File::Spec->file_name_is_absolute($logdir);
    $self->{+LOGDIR} = $logdir;

    if (-e $logdir) {
        croak "logdir '$logdir' exists but is not a directory" unless -d $logdir;
        opendir(my $dh, $logdir) or croak "Cannot read logdir '$logdir': $!";
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        croak "logdir '$logdir' is not empty -- refusing to clobber"
            if @entries;
    }

    make_path("$logdir/services");

    return;
}

# Populate the harness's scalar/hash/array slots with their default
# values. Mass-defaulter; keeps init() short by collecting every slot
# whose default does not depend on validation.
sub _init_default_slots {
    my $self = shift;

    $self->{+NAME}                      //= 'harness';
    $self->{+JOB_ID}                    //= gen_uuid();
    $self->{+KILL_TIMEOUT}              //= 15;
    $self->{+PARENT_PIDS}               //= [];
    $self->{+STATE}                     //= 'running';
    $self->{+QUEUE}                     //= [];
    $self->{+RUN_STATES}                //= {};
    $self->{+SCHEDULER}                 //= {};
    $self->{+RUNNING_JOBS}              //= {};
    $self->{+IN_FLIGHT_COUNT}           //= 0;
    $self->{+RESOURCE_SERVICES}         //= {};
    $self->{+PID_INDEX}                 //= Test2::Harness2::PidIndex->new(harness => $self);
    $self->{+SPAWN_GATEWAY}             //= Test2::Harness2::SpawnGateway->new(harness => $self);
    $self->{+RUN_FLAGS}                 //= {};
    $self->{+PENDING_SYNTH_COMPLETIONS} //= {};
    $self->{+PENDING_SPAWN_REQUESTS}     //= {};
    $self->{+PENDING_PRELOAD_SPAWNS}     //= {};
    $self->{+RESOURCES_AWAITING_PRELOAD} //= {};
    $self->{+KNOWN_PRELOAD_NAMES}        //= {};
    $self->{+PRELOAD_SPAWN_TIMEOUT_SECS} //= 30;
    $self->{+PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS} //= 30;
    $self->{+COLLECTOR_GRACE_SECS}       //= DEFAULT_COLLECTOR_GRACE_SECS;
    $self->{+COMPLETED_RUNS}             //= {};
    $self->{+WATCH_PIDS}                 //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}                 //= 0;
    $self->{+SUBSCRIBERS}                //= {};
    $self->{+SUBSCRIBER_RETRY}           //= {};

    # Sequential run-ord allocator: every accepted run gets the next
    # ordinal integer starting at 0. The counter is per harness-process;
    # persistent runners reuse the same harness so ords climb
    # monotonically across runs in a session, with gaps possible
    # (e.g. accepted-then-purged runs).
    $self->{+RUN_ORD_COUNTER} //= 1;

    return;
}

# Loggers / observers were removed; the collector now writes its
# own spec/events/report files directly. Constructor args named
# `loggers`, `service_loggers`, `test_loggers`, `extend_loggers`,
# and `extend_test_loggers` are silently swallowed so legacy
# callers do not crash, but they have no effect on the on-disk
# layout.
sub _strip_legacy_logger_slots {
    my $self = shift;
    delete $self->{loggers};
    delete $self->{service_loggers};
    delete $self->{test_loggers};
    delete $self->{extend_loggers};
    delete $self->{extend_test_loggers};
    return;
}

sub _init_resources {
    my $self = shift;

    # The harness no longer mandates the presence of any resource class.
    # An empty resources list is a valid, unlimited-concurrency
    # configuration. Auto-injection of a default JobCount happens at
    # the yath-test layer (App::Yath2::Options::Resource), not here, so
    # callers that construct a harness directly remain in full control
    # of which limiters (if any) participate.
    $self->{+RESOURCES} //= [];

    $self->_install_in_flight_ref($_) for @{$self->{+RESOURCES}};
}

# Hand the resource a scalar ref pointing at our authoritative
# in-flight counter. The resource derefs to read; no per-mutation
# notification loop needed.
sub _install_in_flight_ref {
    my ($self, $res) = @_;
    return unless $res && $res->can('set_in_flight_ref');
    $res->set_in_flight_ref(\$self->{+IN_FLIGHT_COUNT});
    return;
}

#-------------------------------------------------------------------
# Preload routing.
#
# _resolve_preload_for_job($run, $job) walks the job's preload
# preference list (parsed from `HARNESS2: preload ...` at scan time,
# default ['<default>']) and returns one of:
#
#   (undef, 'no_preload')          -> use the direct-fork path.
#   ($resource, 'preload')         -> spawn the test via $resource's
#                                     preload service.
#   (undef, 'defer')               -> at least one candidate is not yet
#                                     ready (transient broken / not yet
#                                     usable); retry on the next
#                                     scheduler tick.
#   (undef, 'broken', $first_name) -> list exhausted with no acceptable
#                                     resolution and nothing
#                                     defer-eligible; caller routes
#                                     through broken_resource_behavior.
#
# A `<no>` token is the explicit opt-out and always resolves to
# no_preload, even when earlier candidates were broken or missing
# (so a user can write `HARNESS2: preload maybe-foo @off` to mean
# "prefer maybe-foo, otherwise run unpreloaded").
#
# A `<default>` token resolves to the per-run default (if one exists
# for the current run) and falls through to the global default; if
# neither default is configured, `<default>` resolves to no_preload
# (its implicit <no> fallback per AI_DOCS/2026-05-10-preload-rework-design.md §6.1).
#
# Default determination per scope (cached on first call per harness
# state; recomputed when the resource list changes):
#
#   - per-run default: exactly one Resource::Preload in run scope for
#     this $run AND it is a role consumer.
#   - global default: the Resource::Preload named 'default' if it
#     exists; otherwise the sole global Resource::Preload role
#     consumer if exactly one is present.
#-------------------------------------------------------------------
sub _resolve_preload_for_job {
    my ($self, $run, $job) = @_;

    my $prefs = $job->test_file->preload_preferences;
    return (undef, 'no_preload') unless $prefs && @$prefs;

    my $idx = $self->_index_preloads_for_run($run);

    my $deferred = 0;
    my $first_name;

    for my $entry (@$prefs) {
        $first_name //= $entry;

        return (undef, 'no_preload') if $entry eq '<no>';

        if ($entry eq '<default>') {
            my $cand = $idx->{run_default} // $idx->{global_default};
            return (undef, 'no_preload') unless $cand;    # implicit <no>
            my $verdict = _classify_preload_state($cand);
            return ($cand, 'preload') if $verdict eq 'usable';
            $deferred++                if $verdict eq 'defer';
            return (undef, 'no_preload') if $verdict eq 'permanent';
            next;
        }

        # Bare name: per-run preferred over global.
        my $cand = $idx->{by_run}{$entry} // $idx->{by_global}{$entry};
        next unless $cand;    # missing: skip; broken verdict comes from exhaustion

        my $verdict = _classify_preload_state($cand);
        return ($cand, 'preload') if $verdict eq 'usable';
        $deferred++              if $verdict eq 'defer';
        # permanent: keep scanning -- a later <no>/named candidate may accept.
    }

    return (undef, 'defer') if $deferred;
    return (undef, 'broken', $first_name // '');
}

# Build (scope, name) index of preload resources visible to this run.
# Per-run preloads are only included when their run_id matches.
sub _index_preloads_for_run {
    my ($self, $run) = @_;

    my @all = (
        @{$self->{+RESOURCES} || []},
        (ref($run) ? @{$run->resources // []} : ()),
    );
    my @preloads = grep {
        blessed($_) && $_->isa('Test2::Harness2::Resource::Preload')
    } @all;

    my $run_id = ref($run) ? $run->run_id : undef;

    my (%by_global, %by_run, @globals_role, @run_role);
    my ($global_named_default, $run_named_default);

    for my $r (@preloads) {
        my $name = $r->name;
        if ($r->scope eq 'run') {
            my $rid = ref($r->run) ? $r->run->run_id : undef;
            next unless defined $run_id && defined $rid && $run_id eq $rid;
            $by_run{$name}     = $r;
            push @run_role => $r if $r->is_role_consumer;
            $run_named_default = $r if $name eq 'default';
        }
        else {
            $by_global{$name}     = $r;
            push @globals_role => $r if $r->is_role_consumer;
            $global_named_default = $r if $name eq 'default';
        }
    }

    # Default precedence: an explicit `default`-named preload (the
    # bare-module bucket from `-P Foo`) wins over the "exactly one
    # role consumer" rule.
    return {
        by_global      => \%by_global,
        by_run         => \%by_run,
        global_default => $global_named_default // (@globals_role == 1 ? $globals_role[0] : undef),
        run_default    => $run_named_default    // (@run_role == 1     ? $run_role[0]     : undef),
    };
}

sub _classify_preload_state {
    my ($r) = @_;
    return 'permanent' if $r->is_permanent_broken;
    return 'usable'    if $r->is_usable;
    return 'defer';                  # transient broken OR not yet ready
}

#-------------------------------------------------------------------
# Per-run pid bookkeeping.
#
# All state and behavior lives on $self->pid_index (a
# Test2::Harness2::PidIndex). The eight underscore-prefixed methods
# below are thin compatibility shims kept here so that:
#
#   - Test2::Harness2::Role::ResourceServiceHost can keep calling
#     $self->_resource_service_tracked / $self->_resource_service_forgotten
#     against the harness as the role's host (the role declares no-op
#     stubs and lets the host override).
#
#   - Existing in-tree tests can keep calling the underscore names on
#     the harness directly.
#
# New code should call $self->pid_index->register etc. directly.
#-------------------------------------------------------------------

sub _register_run_pid          { my $self = shift; $self->{+PID_INDEX}->register(@_) }
sub _forget_run_pid            { my $self = shift; $self->{+PID_INDEX}->forget(@_) }
sub _run_for_pid               { my $self = shift; $self->{+PID_INDEX}->run_for_pid(@_) }
sub _pids_for_run              { my $self = shift; $self->{+PID_INDEX}->pids_for_run(@_) }
sub _kill_run                  { my $self = shift; $self->{+PID_INDEX}->kill_run(@_) }
sub _await_run_exit            { my $self = shift; $self->{+PID_INDEX}->await_run_exit(@_) }
sub _resource_service_tracked  { my $self = shift; $self->{+PID_INDEX}->resource_service_tracked(@_) }
sub _resource_service_forgotten { my $self = shift; $self->{+PID_INDEX}->resource_service_forgotten(@_) }

sub start {
    my ($class, %args) = @_;

    my $test_run     = delete $args{test_run};
    my $finish_after = delete $args{finish_after_initial_run};
    my $caller_pid   = $$;

    $args{parent_pids} //= [$caller_pid];

    # If ipcm_info was already provided (e.g. by spawn()), reuse it.
    # Otherwise spawn a fresh IPC bus now.  Keep $ipcm_guard alive for the
    # rest of start() so the IPC bus is not torn down before the service
    # process connects.  POSIX::_exit bypasses Perl destructors, so the
    # guard never fires in either the service child or the collector parent.
    my $ipcm_guard;
    unless ($args{ipcm_info}) {
        $ipcm_guard = ipcm_spawn(ipc_default_spawn_args());
        $args{ipcm_info} = $ipcm_guard->info;
    }

    # Construct the service object in the pre-fork process.  init() creates
    # $workdir/logs/services/.
    my $self = $class->new(%args);

    # Everything the interpose child needs to do after the pipes are wired up
    # is packaged here so it can either run inline (the normal path) or be
    # handed to a caller-provided Long::Jump point via jump_to.
    my $run_service = sub {
        # The EventEmitter defaults wrap STDOUT and, when
        # T2_HARNESS2_PIPE_COUNT advertises separate pipes, STDERR for the
        # sync marker. The interposing collector is responsible for
        # publishing that env var (see Collector::_interpose_child). We
        # use the process-wide cached instance so anything else in this
        # service that emits (e.g. a formatter running in the same
        # process) shares one wrapper around the real FDs.
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->std;

        if ($test_run) {
            $self->request_handler_queue_test_run($test_run);
            $self->{+FINISH_AFTER_INITIAL_RUN} = 1 if $finish_after;
        }

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    my $jump_to = $self->{+JUMP_TO};

    # The interpose collector has no parent service to notify -- it
    # is the top of its own tree. ipc_parent stays undef. ipc_harness
    # points at the service-side name so the collector identifies its
    # owning service even though it has no upward IPC peer. bus_id is
    # passed explicitly because the harness's own collector has no
    # parent to derive from.
    Test2::Harness2::Collector->interpose(
        type        => 'Service',
        id          => $self->{+NAME},
        logdir      => $self->{+LOGDIR},
        ipcm_info   => $self->ipcm_info,
        ipc_parent  => undef,
        ipc_run     => undef,
        ipc_harness => $self->{+NAME},
        bus_id      => "collector:service:" . $self->{+NAME},
        parser      => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids => [$caller_pid],
        spec        => {service_name => $self->{+NAME}, role => 'harness'},
        (defined($jump_to) ? (jump_to => $jump_to, jump_payload => $run_service) : ()),
    );

    # Reached only in the interpose child on the non-jump path; with jump_to
    # set the longjump has already handed $run_service to the setjump caller.
    $run_service->();
}

sub spawn {
    my ($class, %args) = @_;

    my $test_run     = delete $args{test_run};
    my $finish_after = delete $args{finish_after_initial_run};
    my $protocol     = delete $args{protocol};

    $args{parent_pids} //= [$$];

    # Spawn the IPC bus in the parent so both parent and child share the same
    # connection info.  Use guard => 0 so the parent does not try to tear down
    # the bus when the Spawn object goes out of scope; the child owns it.
    # Caller-supplied $protocol is appended last so it overrides the default
    # protocol from ipc_default_spawn_args().
    my @ipcm_args = (ipc_default_spawn_args(), guard => 0);
    push @ipcm_args => (protocol => $protocol) if defined $protocol && length $protocol;
    my $ipcm = ipcm_spawn(@ipcm_args);
    $args{ipcm_info} = $ipcm->info;

    my $pid = fork // die "fork: $!";

    if ($pid) {
        # Parent: build the handle and block until the service is ready to
        # accept requests (same pattern as ipcm_service's post-fork wait).
        require Test2::Harness2::Spawn;
        my $handle = Test2::Harness2::Spawn->new(
            pid       => $pid,
            ipcm_info => $args{ipcm_info},
            workdir   => $args{workdir},
            name      => $args{name} // 'harness',
        );

        my $timeout = 10;
        my $start   = time;
        until ($handle->handle->ready) {
            die "Timeout waiting for harness service to come up after ${timeout}s\n"
                if time - $start > $timeout;

            tinysleep(0.02);
        }

        return $handle;
    }

    # Child: run the service via start().  ipcm_info is already set so
    # start() will skip the second ipcm_spawn() call.
    $class->start(
        %args,
        ($test_run     ? (test_run                 => $test_run)     : ()),
        ($finish_after ? (finish_after_initial_run => $finish_after) : ()),
    );

    # start() never returns; POSIX::_exit is called inside.
    POSIX::_exit(255);
}

# ipcm_info is stored as the bare 'ipcm_info' key (not a HashBase slot)
# because spawn/start flow passes it in through that name. The rest of
# the IPC::Manager::Role::Service contract (orig_io, pid, set_pid,
# watch_pids, handle_request) is provided by Role::Service.
sub ipcm_info { $_[0]->{ipcm_info} }

sub request_handler_queue_test_run {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'service not accepting new runs'}
        if $self->{+STATE} ne 'running';

    my $files = $payload->{files} || [];
    return {ok => 0, error => "'files' must be a non-empty arrayref"}
        unless ref($files) eq 'ARRAY' && @$files;

    if (my $err = $self->_validate_run_hash_seed($payload->{hash_seed})) {
        return {ok => 0, error => $err};
    }

    # Run ids are owned by the harness; a caller-supplied value would
    # collide with the counter.
    return {ok => 0, error => "'run_id' is allocated by the harness; do not pass it"}
        if defined $payload->{run_id};

    my $run_id = $self->{+RUN_ORD_COUNTER}++;

    my ($resources_ok, $resources_or_err) = $self->_rehydrate_run_resources($payload->{resources});
    return {ok => 0, error => $resources_or_err} unless $resources_ok;
    my @run_resources = @$resources_or_err;

    my $ok = eval {
        my $run = Test2::Harness2::Run->from_files(
            files  => $files,
            run_id => $run_id,
            (defined $payload->{hash_seed} ? (hash_seed => $payload->{hash_seed}) : ()),
            (defined $payload->{chdir}     ? (chdir     => $payload->{chdir})     : ()),
            (@run_resources                ? (resources => \@run_resources)       : ()),
        );

        # Per-run Resource::Preload entries arrived with scope='run'
        # but no Run object yet; finish the link now before the
        # scheduler reads services() / status() off the resource.
        for my $r (@run_resources) {
            next unless $r->can('set_run');
            next unless eval { $r->scope eq 'run' };
            eval { $r->set_run($run); 1 };
        }

        push @{$self->{+QUEUE}} => $run;
        $self->_install_in_flight_ref($_) for @{$run->resources // []};
        $self->{+RUN_STATES}->{$run->run_id} = Test2::Harness2::Run::State->new(
            run_id     => $run->run_id,
            created_at => $run->created_at,
            pending    => [map { $_->job_id } @{$run->jobs}],
        );
        $self->_scheduler_queue_run($run);
        1;
    };
    return {ok => 0, error => "$@"} unless $ok;

    my $run = $self->{+QUEUE}->[-1];

    # Flat run_id / queued_at / job_ids alongside the nested run_data:
    # Renderer::Driver's lifecycle synthesizer reads the flat keys
    # off the harness facet to build harness_job_queued events that
    # increment the progress bar's T (todo) counter. run_data is
    # kept for downstream consumers that still want the full TO_JSON
    # dump.
    $self->emit_service_event(
        kind      => 'run_queued',
        run_id    => $run->run_id,
        queued_at => $run->created_at,
        job_ids   => [map { $_->job_id } @{$run->jobs}],
        run_data  => $run->TO_JSON,
    );

    return {ok => 1, run_id => $run->run_id};
}

# --set-hash-seed compatibility check. When both the harness and the
# run carry an explicit seed they must match: any global preload tied
# to the harness was spawned with the harness's seed in
# PERL_HASH_SEED, and a run asking for a different value cannot
# reuse those preload processes. Either side unset is accepted -- the
# harness's seed propagates to children via env when the run has no
# opinion, and the run's seed wins in PERL_HASH_SEED when the harness
# was started without one. Returns an error string when incompatible,
# or undef when OK.
sub _validate_run_hash_seed {
    my ($self, $run_seed) = @_;

    my $harness_seed = $self->{+HASH_SEED};
    return undef unless defined($run_seed) && length $run_seed;
    return undef unless defined($harness_seed) && length $harness_seed;
    return undef if $run_seed eq $harness_seed;

    return "--set-hash-seed=$run_seed on the run does not match "
        . "--set-hash-seed=$harness_seed on the harness; preload was started "
        . "with seed $harness_seed and cannot be reused";
}

# Build per-run Resource instances from the IPC-recipe form:
# [ [class, @ctor_args], ... ]. Each class gets parse_options applied
# (when defined) so the constructor sees the same kwargs the harness-
# global resources do. Returns (1, \@instances) on success, or
# (0, "error string") on failure.
sub _rehydrate_run_resources {
    my ($self, $spec) = @_;
    return (1, []) unless defined $spec;
    return (0, "'resources' must be an arrayref") unless ref($spec) eq 'ARRAY';

    my @out;
    my $ok = eval {
        for my $entry (@$spec) {
            die "resources entry must be an arrayref\n"
                unless ref($entry) eq 'ARRAY';
            my ($class, @args) = @$entry;
            die "resources entry missing class\n"
                unless defined $class && length $class && !ref $class;
            load_module($class);
            my @ctor_args = $class->can('parse_options')
                ? $class->parse_options(@args)
                : @args;
            push @out, $class->new(@ctor_args);
        }
        1;
    };
    return (0, "failed to build per-run resources: $@") unless $ok;
    return (1, \@out);
}

sub request_handler_status {
    my $self = shift;

    my $queue = [
        map {
            my $rs = $self->{+RUN_STATES}->{$_->run_id};
            {
                run_id  => $_->run_id,
                pending => $rs ? [@{$rs->pending}] : [],
                running => $rs ? [@{$rs->running}] : [],
                done    => $rs ? [@{$rs->done}]    : [],
            }
        } @{$self->{+QUEUE}}
    ];

    my @running = map {
        my $cur = $_;
        {
            run_id    => $cur->{run}->run_id,
            job_id    => $cur->{job}->job_id,
            test_file => $cur->{job}->test_file_rel,
            pid       => $cur->{pid},
            started   => $cur->{started_at},
        };
    } values %{$self->{+RUNNING_JOBS}};

    my @resources = map { $_->status } @{$self->{+RESOURCES}};

    # Per-service entries (preload + non-preload alike). Surfaces
    # via_preload for operator visibility — `yath ps` / `yath resources`
    # read this section to tell preload-mediated services apart from
    # standalone ones.
    my @services;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        # Skip entries whose pid is no longer reachable. RESOURCE_SERVICES is
        # not pruned synchronously when a service dies (the SIGCHLD reaper runs
        # asynchronously, and a reload of a preload can leave the old pid in
        # the hash for a tick or two), so without this guard `yath ps` /
        # `yath resources` would render a row with stale data for a dead pid.
        next unless defined $info->{pid} && kill 0 => $info->{pid};

        push @services, {
            pid           => $info->{pid},
            name          => $info->{name},
            service_class => $info->{service_class},
            scope         => $info->{scope},
            run_id        => (ref($info->{run}) && $info->{run}->can('run_id') ? $info->{run}->run_id : $info->{run}),
            via_preload   => $info->{via_preload} ? 1 : 0,
            started_at    => $info->{started_at},
        };
    }

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            job_id  => $self->{+JOB_ID},
            workdir => $self->{+WORKDIR},
            state   => $self->{+STATE},
        },
        queue     => $queue,
        running   => \@running,
        resources => \@resources,
        services  => \@services,
    };
}

# yath reload: enumerate the preload services this harness owns so
# the client can dispatch reload requests to each one without taking
# the harness's dispatcher offline. Run-scoped preloads are
# intentionally skipped; reloading a run-scoped preload mid-run would
# invalidate the test state it was built for.
#
# 'name' in the response is the bus-level peer name the caller addresses
# over IPC (preload-<n> for global), not the host-side tracking name
# (which is just <n>). 'preload' is the bare preload name for display.
sub request_handler_list_preloads {
    my $self = shift;

    my @out;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        next unless ($info->{service_class} // '') eq 'Test2::Harness2::PreloadService';
        next unless ($info->{scope}         // '') eq 'global';
        next unless defined $info->{pid} && kill 0 => $info->{pid};

        my $res        = $info->{resource};
        my $preload    = (ref($res) && $res->can('name') ? $res->name : ($info->{name} // '?'));
        my $bus_name   = (ref($res) && $res->can('scope')) ? _preload_peer_name($res) : "preload-$preload";

        push @out => {
            pid     => $info->{pid},
            name    => $bus_name,
            preload => $preload,
            scope   => $info->{scope},
        };
    }
    return {ok => 1, preloads => \@out};
}

# yath abort: latch user_abort onto one or all live runs. Pending
# jobs in those runs flow through the existing aborted-run synth-fail
# path (see _handle_broken_resource); currently running jobs are left
# alone (that matches the documented "remove pending tests, leave the
# runner active" semantics).
sub request_handler_abort_run {
    my ($self, $payload, $msg) = @_;

    my $states = $self->{+RUN_STATES} // {};

    my @target_ids;
    if ($payload->{all}) {
        @target_ids = sort keys %$states;
    }
    elsif (defined $payload->{run_id}) {
        return {ok => 0, error => "no run with id '$payload->{run_id}'"}
            unless $states->{$payload->{run_id}};
        @target_ids = ($payload->{run_id});
    }
    else {
        return {ok => 0, error => 'request must set either run_id or all'};
    }

    my @aborted;
    for my $rid (@target_ids) {
        my $rs = $states->{$rid} or next;
        next if defined $rs->aborted_reason;    # idempotent
        $rs->latch_aborted_reason('user_abort');
        push @aborted, $rid;
    }
    return {ok => 1, aborted => \@aborted};
}

sub request_handler_finish {
    my $self = shift;
    return {ok => 0} unless $self->{+STATE} eq 'running';
    $self->{+STATE} = 'finishing';
    return {ok => 1};
}

# Idle-check used by the test command (and any caller that wants to
# wait for the harness to drain before requesting termination).
# Returns {ok => 1, idle => 1} when there is no other pending work
# the harness still needs to do for the asking peer:
#
#   - the harness's outbox to that peer is empty
#   - no runs are active or queued
#   - no in-flight subscription deltas remain
#
# The current request itself is NOT counted: the response that goes
# back is queued AFTER this handler returns, so at handler-time the
# outbox does not yet contain it. The caller therefore polls until
# idle == 1, then issues finish/terminate without racing pending
# events.
sub request_handler_has_pending_messages {
    my ($self, $payload, $msg) = @_;

    my $peer = $payload->{peer} // ($msg ? $msg->from : undef)
        or return {ok => 0, error => "'peer' is required (or supply a from-bearing msg)"};

    my $client = $self->client;

    # IPC::Manager 0.000034 (cpanfile minimum) provides the full
    # Outbox API as no-op fallbacks on every client backend, so
    # pending_sends_to is always callable -- non-Outbox clients
    # return 0 without walking anything.
    my $pending = $client->pending_sends_to($peer);

    # "running" used to count live RunService processes; with
    # them gone, count active jobs instead. The semantic the
    # caller relies on is "is the harness still doing work for
    # the queue", which RUNNING_JOBS captures.
    my $running = scalar keys %{$self->{+RUNNING_JOBS} // {}};
    my $queued  = scalar @{$self->{+QUEUE}             // []};

    return {
        ok      => 1,
        idle    => ($pending == 0 && $running == 0 && $queued == 0) ? 1 : 0,
        pending => $pending,
        running => $running,
        queued  => $queued,
    };
}

# Per-run pass/fail + per-job verdicts. A completed run's final
# snapshot is stashed in COMPLETED_RUNS by _handle_run_state_update
# at the moment it sees the run close out; this handler serves from
# that cache. A still-running run returns state => 'running' with
# no pass/fail so callers can poll.
sub request_handler_run_results {
    my ($self, $payload) = @_;

    my $run_id = $payload->{run_id};
    return {ok => 0, error => "'run_id' is required"}
        unless defined $run_id;

    if (my $info = $self->{+COMPLETED_RUNS}->{$run_id}) {
        return {ok => 1, %$info};
    }

    if (grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []}) {
        return {ok => 1, state => 'running', run_id => $run_id};
    }

    return {ok => 0, error => "unknown run '$run_id'"};
}

sub run_on_general_message {
    my ($self, $msg) = @_;

    # Drain any pending retries at the top of each message tick so
    # temporary send failures resolve promptly when the bus catches up.
    $self->_drain_subscriber_retries;

    my $content = $msg->content;
    my $kind    = ref($content) eq 'HASH' ? $content->{kind} : undef;

    # The act of receiving this message has already woken the service's event
    # loop. On the next run_on_all iteration the scheduler re-ticks. Nothing
    # else to do.
    return if defined $kind && $kind eq 'job_complete_notify';

    # Run-service aggregation: the run service owns the authoritative
    # Run state and sends us a full-snapshot mutation on every change.
    # We mirror it into the Run we're tracking so the scheduler sees
    # the same pending / running / done the run service sees.
    # run_state_update used to come in from RunService over IPC and
    # populated RUN_STATES + drove subscriber fan-out. Both
    # responsibilities live in-process now (Stage 9 of the
    # RunService flatten); the dispatch is gone.

    # Run-service aggregation: per-job release signal. The scheduler
    # needs resource release and a wake-up; the final verdict already
    # flowed through the run_state_update channel (and is logged in
    # the run's own jsonl, not here).
    return $self->_handle_job_release($content)
        if defined $kind && $kind eq 'job_release';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    return $self->_handle_preload_state_message($kind, $content)
        if defined $kind && $kind =~ m/^preload_(?:ready|broken)$/;

    return $self->_handle_resource_service_started($content)
        if defined $kind && $kind eq 'resource_service_started';

    return $self->{+SPAWN_GATEWAY}->handle_spawned($content)
        if defined $kind && $kind eq 'script_spawned';

    # Per-job lifecycle. After Stage 4 of the RunService flatten the
    # auditor sends test_job_* events to the harness directly (the
    # collector's ipc_run was repointed). The harness owns Run::State
    # mutation and the run-level event emission that used to live in
    # RunService.
    return $self->_handle_test_job_started($content)
        if defined $kind && $kind eq 'test_job_started';

    return $self->_handle_test_job_diagnosing($content)
        if defined $kind && $kind eq 'test_job_diagnosing';

    return $self->_handle_test_job_failing($content)
        if defined $kind && $kind eq 'test_job_failing';

    return $self->_handle_test_job_completed($content)
        if defined $kind && $kind eq 'test_job_completed';

    # Lifecycle reflection from child collectors that route their
    # collector_start/_end up to the harness: run-service collectors
    # and global services. The harness collector itself has no parent
    # and skips emission entirely so we never receive its own pair.
    return $self->_handle_collector_start($content)
        if defined $kind && $kind eq 'collector_start';

    return $self->_handle_collector_end($content)
        if defined $kind && $kind eq 'collector_end';

    warn "Test2::Harness2: unhandled general message kind: " . (defined $kind ? "'$kind'" : '(none)') . "\n";

    return;
}

# Reflect a collector_start IPC (from a run-service collector or a
# global-service collector) into the harness's own outgoing event
# stream. The harness's own collector picks it up via the standard
# pipeline and writes a harness_collector_start row into
# services/harness/events.jsonl.zst. That row is the entry-point a
# Log iterator follows to descend into a run's or global service's
# events.jsonl.zst.
sub _handle_collector_start {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->{+EMITTER} or return;
    # Emit as a top-level harness_collector_start facet (NOT nested
    # under facet_data.harness) so the Log iterator's depth-first walk
    # can detect it via $event->{facet_data}{harness_collector_start}.
    $em->emit_raw({
        facet_data => {
            harness_collector_start => {%$content},
        },
    });

    return;
}

sub _handle_collector_end {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $em = $self->{+EMITTER} or return;
    $em->emit_raw({
        facet_data => {
            harness_collector_end => {%$content},
        },
    });

    return;
}

#-------------------------------------------------------------------
# Per-job lifecycle handlers. These mutate RUN_STATES->{$run_id}
# in-process, emit a run-level lifecycle event onto the harness's
# own service event stream, and broadcast the new state snapshot to
# subscribed peers. They moved here from RunService when the auditor
# was redirected to talk to the harness directly.
#
# Per-run side state (first-fail latch, completed-job idempotency
# guard, per-job result snapshots that feed the eventual aggregate
# verdict) lives on RUN_FLAGS->{$run_id} so it stays scoped to the
# right run when multiple runs are active.
#-------------------------------------------------------------------

# Initialize / fetch the side-state hash for this run. Idempotent.
sub _run_flags {
    my ($self, $run_id) = @_;
    return $self->{+RUN_FLAGS}->{$run_id} //= {
        completed_job_ids    => {},
        completed_job_states => {},
        failing_emitted      => 0,
        pass                 => 1,
    };
}

sub _handle_test_job_started {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    # Preload-routed jobs landed a placeholder RUNNING_JOBS entry at
    # _spawn_via_preload time; the auditor's collector_pid is the
    # first concrete pid the harness sees for the job. Fill in pid +
    # register in RUN_PIDS so the rest of the reap / watchdog
    # plumbing sees the entry the same way it does for direct-spawn
    # jobs. Drop the matching PENDING_SPAWN_REQUESTS row so the
    # watchdog forgets about it.
    my $cur = $self->{+RUNNING_JOBS}->{$job_id};
    if ($cur && $cur->{awaiting_preload_pid}) {
        my $cpid = $content->{collector_pid} // $content->{pid};
        if (defined $cpid) {
            $cur->{pid}                  = $cpid;
            delete $cur->{awaiting_preload_pid};
            $self->{+PID_INDEX}->register(
                $run_id, $cpid,
                kind       => 'collector',
                job_id     => $job_id,
                job_try    => $content->{job_try},
                started_at => $content->{stamp} // time,
            );
        }
        delete $self->{+PENDING_SPAWN_REQUESTS}->{"$run_id\0$job_id"};
    }

    my $rstate = $self->{+RUN_STATES}->{$run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run_id);

    my $started_at = $content->{stamp} // time;

    # pending -> running. Out-of-order or duplicate started messages
    # are tolerated; mark_running is idempotent against running/done.
    my $ok  = eval { $rstate->mark_running($job_id); 1 };
    my $err = $@;
    warn "Test2::Harness2: could not mark job '$job_id' running for run '$run_id': $err"
        unless $ok;

    $rstate->seed_job_result($job_id, started_at => $started_at);

    $self->emit_service_event(
        kind     => 'job_started',
        stamp    => $started_at,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
        },
    );

    $self->_broadcast_run_state($run_id);
    return;
}

sub _handle_test_job_diagnosing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    $self->emit_service_event(
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

sub _handle_test_job_failing {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    $self->emit_service_event(
        kind     => 'job_failing',
        stamp    => time,
        run_id   => $run_id,
        job_info => {
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
        },
    );

    my $flags = $self->_run_flags($run_id);
    unless ($flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $self->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $content->{job_id},
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    return;
}

sub _handle_test_job_completed {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id} // return;
    my $job_id = $content->{job_id} // return;

    my $flags = $self->_run_flags($run_id);

    # Idempotent against the auditor + watchdog race: first wins.
    return if $flags->{completed_job_ids}{$job_id};
    $flags->{completed_job_ids}{$job_id} = 1;

    # Snapshot the full payload so the run-aggregate path can build
    # without disk reads.
    $flags->{completed_job_states}{$job_id} = {%$content};

    if (!$content->{pass} && !$flags->{failing_emitted}) {
        $flags->{failing_emitted} = 1;
        $flags->{pass}            = 0;
        $self->emit_service_event(
            kind    => 'run_failing',
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $content->{job_try},
            stamp   => time,
        );
    }

    my $rstate = $self->{+RUN_STATES}->{$run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run_id);

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

    $self->emit_service_event(
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

    $self->_broadcast_run_state($run_id);
    return;
}

# Emit the terminal run_completed + collector_report two-facet
# event from the harness's own emitter. Built from per-job state
# accumulated in RUN_FLAGS as test_job_completed messages came in.
# The renderer's harness_run_end synthesizer reads pass/fail counts
# off the collector_report facet (see Renderer::Driver line 295+).
sub _emit_run_completed {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $flags = $self->{+RUN_FLAGS}->{$run_id} or return;
    return if $flags->{run_completed_emitted}++;

    my $em = $self->{+EMITTER} or return;

    my $now    = time;
    my $report = $self->_build_collector_report($run, $now);

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
# run-level aggregate the renderer summarizes. Mirrors the
# previous RunService._build_collector_report.
sub _build_collector_report {
    my ($self, $run, $now) = @_;
    $now //= time;

    my $run_id = $run->run_id;
    my $flags  = $self->{+RUN_FLAGS}->{$run_id} //= {};
    my $states = $flags->{completed_job_states} // {};

    my $passed  = 0;
    my $failed  = 0;
    my $aborted = 0;

    my %jobs_by_id;
    for my $jid (keys %$states) {
        my $st       = $states->{$jid} // {};
        my $job_pass = $st->{pass} ? 1 : 0;
        if ($job_pass) {
            $passed++;
        }
        else {
            $failed++;
            $aborted++ if $st->{synth};
        }

        # Resolve test file from the Run's queue-time job spec.
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
        $jobs_by_id{$jid} = {
            job_id   => $jid,
            file     => $file,
            pass     => $job_pass,
            tries    => $tries,
            subtests => [@{$st->{subtests} // []}],
        };
    }

    # Stable ordering: order from the Run's job spec; remaining ids
    # appended sorted so the array stays deterministic.
    my @ordered;
    my %placed;
    for my $job (@{$run->jobs}) {
        my $jid = $job->job_id;
        next unless exists $jobs_by_id{$jid};
        push @ordered, $jobs_by_id{$jid};
        $placed{$jid} = 1;
    }
    for my $jid (sort keys %jobs_by_id) {
        next if $placed{$jid};
        push @ordered, $jobs_by_id{$jid};
    }

    my $total = scalar @ordered;

    return {
        pass         => $flags->{pass} ? 1 : 0,
        started_at   => $flags->{started_at},
        ended_at     => $flags->{ended_at} // $now,
        total_jobs   => $total,
        passed_jobs  => $passed,
        failed_jobs  => $failed,
        aborted_jobs => $aborted,
        jobs         => \@ordered,
    };
}

# Push a snapshot of the named run's State out to subscribers AND
# trigger run-finalization if the run is now complete. This
# replaces the round-trip via run_state_update IPC that RunService
# used to drive: subscribers still see one snapshot per state
# change, just sourced locally instead of over the bus.
sub _broadcast_run_state {
    my ($self, $run_id) = @_;
    my $rstate = $self->{+RUN_STATES}->{$run_id} or return;
    my $data   = $rstate->TO_JSON;
    $self->_notify_state_subscribers($run_id, $data);

    my ($run) = grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []};
    $self->_finalize_run_if_complete($run) if $run;
    return;
}

# Peer delta callback from IPC::Manager. A negative delta on a
# subscribed peer IS the signal that the peer has left the bus --
# no separate peer_exists() query is needed. Clean unsubscribes
# have already removed the peer from SUBSCRIBERS, so anything that
# reaches this branch is an unexpected departure; we warn and drop
# the registration (plus any queued retries).
sub run_on_peer_delta {
    my ($self, $delta) = @_;

    return unless ref($delta) eq 'HASH';

    for my $peer (keys %$delta) {
        next unless $delta->{$peer} < 0;
        next unless exists $self->{+SUBSCRIBERS}->{$peer};

        warn "Test2::Harness2: subscriber '$peer' left without unsubscribing\n";
        delete $self->{+SUBSCRIBERS}->{$peer};
        delete $self->{+SUBSCRIBER_RETRY}->{$peer};
    }

    $self->_drain_subscriber_retries;
    return;
}

sub _handle_preload_state_message {
    my ($self, $kind, $content) = @_;

    return unless ref($content) eq 'HASH';
    my $name  = $content->{preload_name};
    my $scope = $content->{scope} // 'global';
    return unless defined $name;

    my $run_id = $content->{run_id};

    # Look in both global resources and every queued run's per-run
    # resources -- a per-run preload's mark_ready signal otherwise
    # never lands on its Resource::Preload and the resolver defers
    # forever.
    my @candidates = @{$self->{+RESOURCES} // []};
    for my $run (@{$self->{+QUEUE} // []}) {
        push @candidates => @{$run->resources // []};
    }

    for my $res (@candidates) {
        next unless blessed($res) && $res->isa('Test2::Harness2::Resource::Preload');
        next unless $res->name eq $name;
        next unless $res->scope eq $scope;
        if ($scope eq 'run') {
            next unless defined $run_id;
            my $r_run = $res->run;
            next unless ref($r_run);
            next unless $r_run->run_id eq $run_id;
        }

        if ($kind eq 'preload_ready') {
            # mark_ready is itself permanent_broken-aware: it no-ops
            # when the resource has been flagged permanent_broken, so
            # cross-scope reuses of the same preload name can't promote
            # a sibling resource via a foreign-scope preload_ready.
            $res->mark_ready;
        }
        elsif ($kind eq 'preload_broken') {
            $res->mark_broken;
        }
        last;
    }

    # Drain any dependent resource services that were queued waiting
    # for this preload. preload_ready dispatches them through the
    # preload; permanent preload_broken flushes them to standalone so
    # they still come up (just unpreloaded). Transient preload_broken
    # leaves the queue intact so a subsequent preload_ready can still
    # drain it.
    if ($kind eq 'preload_ready') {
        $self->_drain_resources_awaiting_preload($name);
    }
    elsif ($kind eq 'preload_broken' && $content->{permanent}) {
        $self->_fallback_resources_awaiting_preload($name);
    }

    return;
}

sub _handle_resource_state_message {
    my ($self, $kind, $content) = @_;

    my $name = ref($content) eq 'HASH' ? $content->{resource} : undef;
    return unless defined $name;

    my ($res) = grep { $_->resource_name eq $name } @{$self->{+RESOURCES} // []};
    return unless $res;

    if    ($kind eq 'resource_paused')           { $res->mark_paused }
    elsif ($kind eq 'resource_broken')           { $res->mark_broken }
    elsif ($kind eq 'resource_permanent_broken') { $res->mark_permanent_broken }
    elsif ($kind eq 'resource_resumed' || $kind eq 'resource_ready') {
        # Permanent brokenness is sticky; a resource cannot re-declare itself
        # ready once the harness has ruled it out.
        $res->mark_resumed unless $res->is_permanent_broken;
    }

    return;
}

# ----------------------------------------------------------------------
# Subscription API. Consumers (typically the test command) ask to
# be told when run state changes. The harness is the only service that
# carries this registry; run services publish state upstream via
# _send_to_harness, the harness then fans out to any matching
# subscribers.
#
# Registry shape:
#   { $peer_name => {
#         global => $bool,      # (future) harness-level state
#         runs   => { $id=>1 }, # run ids the subscriber watches
#         state  => $bool,      # want state change messages
#     } }
sub request_handler_subscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "subscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    my $global = $payload->{global} ? 1 : 0;
    my $state  = $payload->{state}  ? 1 : 0;

    my @run_ids;
    push @run_ids => $payload->{run}     if defined $payload->{run};
    push @run_ids => @{$payload->{runs}} if ref($payload->{runs}) eq 'ARRAY';

    # Validate every run_id up front. The harness knows about runs in
    # the live queue and in COMPLETED_RUNS (terminal snapshots).
    for my $rid (@run_ids) {
        next if grep { $_->run_id eq $rid } @{$self->{+QUEUE} // []};
        next if $self->{+COMPLETED_RUNS}->{$rid};
        return {ok => 0, error => "unknown run '$rid'"};
    }

    my $entry = $self->{+SUBSCRIBERS}->{$peer} //= {
        global => 0,
        runs   => {},
        state  => 0,
    };
    $entry->{global} ||= $global;
    $entry->{state}  ||= $state;
    $entry->{runs}->{$_} = 1 for @run_ids;

    # Send an initial state snapshot for each freshly-added run so the
    # subscriber does not need to separately request it.
    if ($state) {
        for my $rid (@run_ids) {
            $self->_send_state_snapshot($peer, run_id => $rid);
        }
    }

    return {ok => 1};
}

sub request_handler_unsubscribe {
    my ($self, $payload, $msg) = @_;

    my $peer = $msg ? $msg->from : undef;
    return {ok => 0, error => "unsubscribe requires an IPC message context"}
        unless defined $peer && length $peer;

    delete $self->{+SUBSCRIBERS}->{$peer};
    delete $self->{+SUBSCRIBER_RETRY}->{$peer};

    return {ok => 1};
}

# Fan-out. Called from _handle_run_state_update. Full snapshot each
# time; consumers diff on their side.
sub _notify_state_subscribers {
    my ($self, $run_id, $run_data) = @_;
    return unless defined $run_id;

    for my $peer (keys %{$self->{+SUBSCRIBERS}}) {
        my $entry = $self->{+SUBSCRIBERS}->{$peer};
        next unless $entry->{state};
        next unless $entry->{runs}->{$run_id};

        $self->_send_to_subscriber(
            $peer => {
                type   => 'state',
                item   => 'run',
                run_id => $run_id,
                state  => $run_data,
            },
        );
    }
    return;
}

sub _send_state_snapshot {
    my ($self, $peer, %params) = @_;
    my $run_id = $params{run_id} or return;

    my $run_data;
    if (grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []}) {
        my $rstate = $self->{+RUN_STATES}->{$run_id};
        $run_data = $rstate ? $rstate->TO_JSON : {run_id => $run_id};
    }
    elsif (my $info = $self->{+COMPLETED_RUNS}->{$run_id}) {
        # Completed snapshot is not a Run-shaped TO_JSON; wrap it so
        # consumers still see the same {type,item,run_id,state} shape.
        $run_data = {
            run_id  => $run_id,
            state   => 'complete',
            results => $info->{results} // {},
            done    => $info->{done}    // [],
            pass    => $info->{pass},
        };
    }
    else {
        return;
    }

    $self->_send_to_subscriber(
        $peer => {
            type   => 'state',
            item   => 'run',
            run_id => $run_id,
            state  => $run_data,
        },
    );
}

# Deliver one message to a subscriber. Uses the service's own
# client to piggy-back on IPC::Manager's internal peer cache
# instead of constructing a new Handle per-peer (Handles are only
# needed when the sender is doing a sync_request and needs to wait
# for a response; a plain send_message() goes through the client
# directly and accepts any named peer on the bus, including
# clients that are not themselves services).
#
# On a send failure we ask the bus whether the peer is still
# registered. If peer_exists() says yes, the failure is transient
# (bus congestion, a racing suspend, etc.) and we queue a retry
# for the next tick. If peer_exists() says no, the peer is gone
# for good; skip the retry and unsubscribe now so we stop sending
# them anything else.
sub _send_to_subscriber {
    my ($self, $peer, $payload) = @_;

    my $ok  = eval { $self->client->send_message($peer, $payload); 1 };
    my $err = $@;

    return if $ok;

    my $peer_alive = eval { $self->client->peer_exists($peer) };
    unless ($peer_alive) {
        warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
        delete $self->{+SUBSCRIBERS}->{$peer};
        delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        return;
    }

    my $retry = $self->{+SUBSCRIBER_RETRY}->{$peer} //= {};
    $retry->{pending} //= [];
    push @{$retry->{pending}} => $payload;

    # Cap per-peer retry queue. A subscriber that never drains will
    # otherwise balloon harness memory. When the cap is hit, drop the
    # oldest payloads (FIFO) and warn once -- the consumer is broken
    # in some way and there is no good way to recover the lost
    # messages, but the harness must stay healthy.
    my $cap = SUBSCRIBER_RETRY_CAP;
    if (@{$retry->{pending}} > $cap) {
        my $excess = @{$retry->{pending}} - $cap;
        splice @{$retry->{pending}}, 0, $excess;
        unless ($retry->{capped_warned}++) {
            warn "Test2::Harness2: subscriber '$peer' retry queue exceeded " . "$cap; dropping oldest payloads.\n";
        }
    }
    return;
}

# Called once per service tick to drain retries. Per-payload the
# same peer_alive gate applies: a send failure is retried while
# the peer is still on the bus, and dropped (with the peer
# unsubscribed) once peer_exists() reports it gone.
sub _drain_subscriber_retries {
    my $self = shift;

    my $retries = $self->{+SUBSCRIBER_RETRY};
    return unless keys %$retries;

    for my $peer (keys %$retries) {
        my $entry = $retries->{$peer};
        my @queue = @{$entry->{pending} // []};
        $entry->{pending} = [];

        my $peer_gone = 0;
        for my $i (0 .. $#queue) {
            my $payload = $queue[$i];
            my $ok      = eval { $self->client->send_message($peer, $payload); 1 };
            my $err     = $@;

            next if $ok;

            my $peer_alive = eval { $self->client->peer_exists($peer) };
            unless ($peer_alive) {
                warn "Test2::Harness2: subscriber '$peer' is gone, unsubscribing: $err\n";
                $peer_gone = 1;
                last;
            }

            # Peer is still on the bus but the send failed again.
            # Keep this payload (and anything after it we have not
            # sent yet) for the next tick so we do not reorder the
            # stream or drop messages just because the bus is
            # momentarily backed up.
            push @{$entry->{pending}} => @queue[$i .. $#queue];
            last;
        }

        if ($peer_gone) {
            delete $self->{+SUBSCRIBERS}->{$peer};
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
        elsif (!@{$entry->{pending}}) {
            delete $self->{+SUBSCRIBER_RETRY}->{$peer};
        }
    }

    return;
}

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS}}];
    return {ok => 1};
}

# Run-service aggregation: replace our mirror Run::State's pending /
# running / done lists (and results map) with the run service's
# authoritative snapshot. When that replacement closes the run out
# (nothing pending, nothing running), tear down the run service and
# emit run_ended.
#
# run_data is the full Run::State->TO_JSON payload; the harness's
# Build the "final" snapshot stashed into COMPLETED_RUNS so that
# callers can query pass/fail via IPC after a run ends but before
# the harness itself exits. Aggregate pass is true when every job
# that reported a result passed; skipped jobs have no result entry
# and therefore do not fail the aggregate.
sub _snapshot_run_results {
    my ($self, $run) = @_;

    my $rstate   = $self->{+RUN_STATES}->{$run->run_id};
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

# Run-service aggregation: per-job release. Looks up the job's
# tracking entry for its assigned resources, releases them, drops
# the entry, and tells the scheduler the job is done. The Run
# mirror's done list is filled in independently from
# run_state_update broadcasts.
sub _handle_job_release {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $job_id = $content->{job_id};
    return unless defined $job_id;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;
    $self->{+IN_FLIGHT_COUNT}--;

    my $run_id = $cur->{run}->run_id;
    $self->{+PID_INDEX}->forget($run_id, $cur->{pid}) if $cur->{pid};
    $self->_scheduler_mark_done($run_id, $job_id);
    $self->_release_job_resources($cur);

    # The job that just finished may have been the last one for
    # its run; check from the scheduler's own perspective.
    $self->_finalize_run_if_complete($cur->{run});
    return;
}

sub _release_job_resources {
    my ($self, $cur) = @_;

    my $assigned = $cur->{assigned_resources} or return;
    my $id       = $cur->{assign_id};

    for my $res (@$assigned) {
        my $ok  = eval { $res->release(id => $id, job => $cur->{job}); 1 };
        my $err = $@;
        warn "failed to release resource '" . $res->resource_name . "': $err"
            unless $ok;
    }
}

# Role::Service hooks. The shared escalator in Role::Service drives the
# loop; these methods only feed and clean up the harness-side tracking.
#
# NOTE: perform_hard_stop kills processes and clears scheduler state;
# it does NOT call teardown() on any resources. Callers that want a
# clean shutdown must invoke run_on_cleanup (or call
# _teardown_run_service explicitly for any per-run resources they
# care about) after perform_hard_stop returns.
sub service_pre_hard_stop {
    my $self = shift;
    # Drain the queue so a racing run_on_all tick cannot schedule
    # fresh work mid-shutdown.
    $self->{+QUEUE} = [];
    return;
}

sub hard_stop_pids {
    my $self = shift;

    my %pids;

    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $pids{$cur->{pid}} //= {} if $cur->{pid};
    }

    # Registered IPC::Manager workers, when present.
    if ($self->can('workers')) {
        $pids{$_} //= {} for keys %{$self->workers // {}};
    }

    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    return %pids;
}

sub service_post_hard_stop {
    my $self = shift;
    # Best-effort resource release for every job we were tracking.
    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $self->_release_job_resources($cur);
    }
    $self->{+RUNNING_JOBS}      = {};
    $self->{+IN_FLIGHT_COUNT}   = 0;
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+PID_INDEX}->clear;
    $self->{+RUN_FLAGS}         = {};
    return;
}

# IPC::Manager service-loop hook: a non-worker child pid was reaped. The
# pids we track here are:
#   - running collectors (one per active job_id)
#   - resource-service processes spawned via service_* methods
# Reparented descendants (subreaper orphans) that we did not spawn also
# land here; they get no handling beyond the drain the service loop did.
#
# IPC::Manager dispatches run_on_pid serially per tick, so the restart
# branch below is not re-entered mid-invocation even though it calls back
# into the resource (which may call track_resource_service). Do not
# introduce unguarded mutation of +RESOURCE_SERVICES from another code
# path that could also execute inside a single tick.
sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    return if $self->_handle_test_collector_exit($pid, $exit);

    # Script-spawn handler returns true only when the pid matched a
    # script-spawn entry definitively. The "race" case stashes the
    # exit speculatively and falls through to the resource-service
    # handler in case the pid actually belongs there.
    return if $self->{+SPAWN_GATEWAY}->handle_pid_exit($pid, $exit);

    # Resource-service exit (the shared host role owns restart-spiral
    # protection, state flags, and re-invocation). Reparented descendants
    # that aren't one of ours silently fall through.
    $self->handle_resource_service_exit($pid, $exit);
    return;
}

# Test-collector exit. The harness owns the collector since Stage 5
# of the RunService flatten, so this is the normal reap site. If
# test_job_completed arrived first, just clear the per-run pid index;
# otherwise arm a synth-completion grace entry so run_on_interval can
# synthesize completion when the auditor never gets to speak (collector
# crash, signal during emit, etc.). Returns true if handled.
sub _handle_test_collector_exit {
    my ($self, $pid, $exit) = @_;

    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        my $run    = $cur->{run};
        my $run_id = $run->run_id;
        my $flags  = $self->{+RUN_FLAGS}->{$run_id};

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
sub run_on_interval {
    my $self = shift;

    $self->_age_pending_spawn_requests;
    $self->_check_pending_preload_spawn_timeouts;
    $self->{+SPAWN_GATEWAY}->poll;

    my $pending = $self->{+PENDING_SYNTH_COMPLETIONS};
    return unless $pending && keys %$pending;

    my $now   = time;
    my $grace = $self->{+COLLECTOR_GRACE_SECS} // DEFAULT_COLLECTOR_GRACE_SECS;

    for my $job_id (keys %$pending) {
        my $entry  = $pending->{$job_id};
        my $run_id = $entry->{run_id};

        # A real test_job_completed arrived inside the grace window
        # -- drop the pending synth.
        my $flags = $self->{+RUN_FLAGS}->{$run_id};
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
        # RUN_FLAGS, run_failing latching, and the
        # collector_report aggregate all see the synthesized
        # entry. pass=0 + zero counts so the renderer surface can
        # distinguish "synthesized fail" from "real fail with
        # known counts".
        $self->_handle_test_job_completed({
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
        # release / scheduler cleanup that _handle_job_release
        # normally does has to fire here too.
        $self->_synth_release_orphan_job($run_id, $job_id, $entry->{pid});
    }

    return;
}

# Counterpart to _handle_job_release for the watchdog path: when
# the auditor never got a chance to send job_release, the harness
# has to release the resources, drop the RUNNING_JOBS entry, mark
# the scheduler done, and trigger run-finalization itself.
sub _synth_release_orphan_job {
    my ($self, $run_id, $job_id, $pid) = @_;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;
    $self->{+IN_FLIGHT_COUNT}--;

    $self->{+PID_INDEX}->forget($run_id, $pid) if $pid;
    $self->_release_job_resources($cur);
    $self->_scheduler_mark_done($run_id, $job_id);
    $self->_finalize_run_if_complete($cur->{run}) if $cur->{run};
    return;
}

sub run_should_end {
    my $self = shift;

    my $has_running = keys %{$self->{+RUNNING_JOBS} // {}} ? 1 : 0;

    if ($self->{+STATE} eq 'terminating') {
        return 1 unless $has_running;
        return 0;
    }

    if ($self->{+STATE} eq 'finishing') {
        return 1 if !$has_running && !@{$self->{+QUEUE}};
        return 0;
    }

    return 0;
}

# Role::Service provides run_on_start. It handles setpgid,
# subreaper registration, and the service_started emit uniformly;
# we only supply the harness-specific startup step.
sub service_on_start {
    my $self = shift;
    $self->start_resource_services($self->{+RESOURCES}, scope => 'global');
    return;
}

sub run_on_cleanup {
    my $self = shift;

    # Snapshot the queue so we can tear down per-run resources for any
    # runs that didn't complete cleanly -- perform_hard_stop drains the
    # queue before returning.
    my @leftover_runs = @{$self->{+QUEUE} // []};

    my $has_running = keys %{$self->{+RUNNING_JOBS} // {}};
    $self->perform_hard_stop if $has_running || @{$self->{+QUEUE}};

    $self->_teardown_run_service($_) for @leftover_runs;

    # Guard every teardown so a throwing resource cannot short-circuit the
    # loop and skip the service_stopped emit that downstream callers rely
    # on to observe a clean shutdown.
    for my $res (@{$self->{+RESOURCES} // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

    $self->emit_service_event(kind => 'service_stopped');
}

sub emit_service_event {
    my ($self, %fields) = @_;
    my $em = $self->{+EMITTER} or return;    # no emitter in tests
    $em->emit_event(%fields);
}

sub TO_JSON {
    my $self = shift;
    return {
        name    => $self->{+NAME},
        job_id  => $self->{+JOB_ID},
        workdir => $self->{+WORKDIR},
        pid     => $self->pid,
    };
}

# Scheduler state. The harness keeps its own pending/running view
# of every queued run, populated once at queue time from the run's
# initial job list and mutated only by the harness's own scheduling
# decisions (launch, skip, completion). It deliberately never
# reads or writes the Run object's pending/running/done arrays
# (those mirror what the run service broadcasts back, which the
# scheduler should not depend on -- the broadcasts can race and
# would otherwise resurrect already-launched jobs into the
# pending list).
sub _scheduler_queue_run {
    my ($self, $run) = @_;
    my $rid = $run->run_id;
    $self->{+SCHEDULER}->{$rid} = {
        pending => [map { $_->job_id } @{$run->jobs}],
        running => {},
        started => 0,
    };
    return;
}

sub _scheduler_pending_for_run {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return [];
    return $s->{pending};
}

sub _scheduler_is_running {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{running}->{$job_id} ? 1 : 0;
}

sub _scheduler_started {
    my ($self, $run_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return 0;
    return $s->{started};
}

sub _scheduler_mark_running {
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
sub _scheduler_mark_pending {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    delete $s->{running}->{$job_id};
    return if grep { $_ eq $job_id } @{$s->{pending}};
    push @{$s->{pending}}, $job_id;
    return;
}

sub _scheduler_mark_done {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    delete $s->{running}->{$job_id};
    return;
}

sub _scheduler_skip {
    my ($self, $run_id, $job_id) = @_;
    my $s = $self->{+SCHEDULER}->{$run_id} or return;
    $s->{pending} = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{started} = 1;
    return;
}

sub _scheduler_drop_run {
    my ($self, $run_id) = @_;
    delete $self->{+SCHEDULER}->{$run_id};
    return;
}

sub _scheduler_run_complete {
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

sub run_on_all {
    my ($self, $activity) = @_;

    # Job completion flows through the run service: test collectors
    # emit test_job_completed to the run service, which aggregates
    # and sends us job_release (for resource release + wake) plus
    # run_state_update (to mirror the Run). The run service's own
    # watchdog synthesizes completion on collector death. Nothing
    # here beyond driving the scheduler forward.
    return if $self->{+STATE} eq 'terminating';

    # Launch as many pending jobs as the active resources permit this tick.
    1 while $self->_try_launch_next_pending;
}

sub _try_launch_next_pending {
    my $self = shift;

    return 0 unless @{$self->{+QUEUE} // []};

    # Runs are processed serially in the order they were queued. Find
    # the first run that is not yet complete from the scheduler's
    # perspective; that becomes the head run for this tick.
    my $head_run;
    for my $run (@{$self->{+QUEUE}}) {
        next if $self->_scheduler_run_complete($run->run_id);
        $head_run = $run;
        last;
    }
    return 0 unless $head_run;

    my $run_id = $head_run->run_id;

    # Lazy per-run resource startup: the first time this run is
    # considered for launch we spin up its resource services.
    $self->_ensure_run_service_started($head_run);

    # Iterate the scheduler's own pending list (authoritative view of
    # what we have not yet attempted), not $run->pending (mirrors run
    # service and can lag behind).
    for my $job_id (@{$self->_scheduler_pending_for_run($run_id)}) {
        my ($job) = grep { $_->job_id eq $job_id } @{$head_run->jobs};
        next unless $job;

        my $outcome = $self->_dispatch_pending_job($head_run, $job);
        return 1 if $outcome eq 'launched';
        next;     # 'defer' or 'skipped'
    }

    return 0;
}

# Per-job dispatch decision for _try_launch_next_pending. Returns
# 'launched' to signal the caller a job was started (and the tick is
# done), or 'defer' to advance to the next pending job. Encapsulates
# the run-aborted short-circuit, preload routing, and resource
# evaluation, plus the unavailable-action / broken-resource branches.
sub _dispatch_pending_job {
    my ($self, $run, $job) = @_;

    my ($decision, $arg, %dec_opts);
    my $preload_resource;

    my $rstate = $self->{+RUN_STATES}->{$run->run_id};
    if ($rstate && defined $rstate->aborted_reason) {
        # Run aborted: every remaining job takes the unavailable-action
        # fail path. aborted=1 distinguishes follow-ups from the
        # original trigger (aborted=0, set by _handle_broken_resource).
        ($decision, $arg) = ('broken', $rstate->aborted_reason);
        $dec_opts{aborted} = 1;
    }
    else {
        # Preload routing runs before the generic resource walk so an
        # unmet preload preference can short-circuit
        # _evaluate_resources_for entirely. Resolver returns:
        #   (undef, 'no_preload')      -> normal direct-fork path
        #   ($resource, 'preload')     -> spawn via preload service
        #   (undef, 'defer')           -> retry next tick
        #   (undef, 'broken', $first)  -> route through broken_resource_behavior
        my ($pres, $pkind, $pextra) = $self->_resolve_preload_for_job($run, $job);
        return 'defer' if $pkind eq 'defer';

        if ($pkind eq 'broken') {
            ($decision, $arg) = ('broken', "preload:$pextra");
        }
        else {
            $preload_resource = $pres;
            ($decision, $arg) = $self->_evaluate_resources_for($run, $job);
        }
    }

    if ($decision eq 'skip') {
        # Resource is healthy but can never grant the slots THIS job
        # demands (e.g. test declares `HARNESS2: slots 8` and per-job
        # cap is 4). Route through the unavailable-action skip launch
        # so the renderer/log show a real skip_all event. The skip
        # launch shares the job-limiter pool and may defer when
        # saturated.
        my $outcome = $self->_launch_unavailable_action_job($run, $job, 'skip', $arg);
        return $outcome eq 'launched' || $outcome eq 'skip' ? 'launched' : 'defer';
    }

    if ($decision eq 'broken') {
        my $outcome = $self->_handle_broken_resource($run, $job, $arg, %dec_opts);
        return $outcome eq 'launched' || $outcome eq 'skip' ? 'launched' : 'defer';
    }

    return 'defer' if $decision eq 'defer';

    $self->_launch_job(
        $run, $job, $arg,
        (defined $preload_resource ? (preload_resource => $preload_resource) : ()),
    );
    return 'launched';
}

# Finalize the run if it's complete: snapshot final results from
# the Run mirror, drop the run from the queue, tear down its per-
# run service, and transition the harness to finishing if we're
# in finish_after_initial_run mode.
#
# Finalization is gated by the Run mirror's is_complete: that is
# the run service's authoritative "all jobs done, here are the
# final results" signal. The scheduler's own pending+running
# view is for launch decisions, not finalization -- it can reach
# empty before the mirror has the results we need to snapshot.
sub _finalize_run_if_complete {
    my ($self, $run) = @_;
    my $run_id = $run->run_id;

    my $rstate = $self->{+RUN_STATES}->{$run_id};
    return unless $rstate && $rstate->is_complete;

    # Idempotent: if we already finalized this run, do nothing.
    return if $self->{+COMPLETED_RUNS}->{$run_id};

    $self->{+COMPLETED_RUNS}->{$run_id} = $self->_snapshot_run_results($run);

    # Emit the terminal run_completed + collector_report event from
    # the harness BEFORE the per-run state is dropped. This used to
    # live in RunService.emit_run_completed; the harness owns Run
    # state now so it owns the aggregate.
    $self->_emit_run_completed($run);
    $self->_write_run_report($run);

    $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];
    delete $self->{+RUN_STATES}->{$run_id};
    delete $self->{+RUN_FLAGS}->{$run_id};
    $self->_scheduler_drop_run($run_id);
    $self->_teardown_run_service($run);
    $self->emit_service_event(
        kind     => 'run_ended',
        run_data => {run_id => $run_id},
    );
    $self->{+STATE} = 'finishing'
        if $self->{+FINISH_AFTER_INITIAL_RUN}
        && $self->{+STATE} eq 'running';

    return;
}

# Dispatch for ($decision eq 'broken'): a needed resource is
# permanently broken. Which of skip / fail / abort to do is governed
# by the harness-level broken_resource_behavior attribute.
#
# All three paths route the job through a real Collector launch --
# skip runs a one-liner that calls skip_all, fail runs a one-liner
# that dies, abort is per-job fail for the whole remaining run.
# That way the auditor and on-disk artifacts are produced the same
# way they would be for a real test; no job is ever silently dropped.
#
# Returns 'launched', 'defer' (limiter full), or 'skip' (the
# unavailable-action launch is impossible: e.g. no job-limiter is
# usable any more).
sub _handle_broken_resource {
    my ($self, $run, $job, $resource_name, %opts) = @_;

    my $behavior = $self->{+BROKEN_RESOURCE_BEHAVIOR};
    my $aborted  = $opts{aborted} ? 1 : 0;

    if ($behavior eq 'skip') {
        return $self->_launch_unavailable_action_job(
            $run, $job, 'skip', $resource_name, aborted => $aborted,
        );
    }

    if ($behavior eq 'fail') {
        return $self->_launch_unavailable_action_job(
            $run, $job, 'fail', $resource_name, aborted => $aborted,
        );
    }

    # abort: record the reason on the run state so every other
    # pending job also takes the fail path (see
    # _try_launch_next_pending), then synthesize fail for THIS job.
    # The scheduler drives the rest one at a time as the job limiter
    # frees slots -- we never try to launch N synth-fail jobs against
    # a single-slot limiter at once. The current job is the trigger;
    # follow-ups arrive through the scheduler's aborted-run branch
    # with aborted => 1 already set on their dec_opts.
    if (my $rstate = $self->{+RUN_STATES}->{$run->run_id}) {
        $rstate->latch_aborted_reason($resource_name);
    }
    return $self->_launch_unavailable_action_job(
        $run, $job, 'fail', $resource_name, aborted => $aborted,
    );
}

# Launch an unavailable-action skip/fail via the normal Collector
# path, using a perl -e one-liner instead of the real test file. Only
# job_limiter resources that are NOT permanent_broken get consulted
# (with a fixed need=1) -- the broken resource itself is of course
# skipped, and non-limiter resources don't participate in accounting
# for one-off unavailable-action runs.
#
# Returns 'launched', 'defer' (limiter full right now), or 'skip' (no
# usable limiter at all, so the unavailable-action launch can never
# run).
sub _launch_unavailable_action_job {
    my ($self, $run, $job, $unavailable_action, $resource_name, %opts) = @_;

    croak "unavailable_action kind must be 'skip' or 'fail' (got '$unavailable_action')"
        unless $unavailable_action eq 'skip' || $unavailable_action eq 'fail';

    my $aborted = $opts{aborted} ? 1 : 0;
    my $reason =
        $aborted
        ? "Run aborted: missing resources: $resource_name"
        : "Missing resources: $resource_name";

    # perl -Ilib -e ... -- <reason>. ARGV carries the reason so we
    # don't have to quote the message into the -e body. -Ilib mirrors
    # the real-test launch in the RunService so Test2::Formatter::Stream2
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
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});
    my @limiters =
        grep { !$_->is_permanent_broken && $_->needed(job => $job) } @all;

    # Availability gate: share the run's job-limiter pool with real
    # tests. If every usable limiter is saturated right now, defer
    # and let the scheduler re-try on the next tick once a slot frees.
    # If a limiter can never accommodate us (-1, which should not
    # happen with need=1 on a single-slot pool but is possible in
    # pathological configurations) the unavailable-action job is
    # skipped outright.
    for my $res (@limiters) {
        my $av = $res->available(job => $job, min => 1, max => 1, need => 1);
        if ($av < 0) {
            $self->_scheduler_skip($run->run_id, $job->job_id);
            $self->_finalize_run_if_complete($run);
            return 'skip';
        }
        return 'defer' if $av == 0;
    }

    $self->_launch_job(
        $run, $job, \@limiters,
        launch      => $launch,
        assign_args => {min => 1, max => 1, need => 1},
    );

    return 'launched';
}

sub _evaluate_resources_for {
    my ($self, $run, $job) = @_;

    # Global resources are consulted first, then per-run resources
    # layered on top. Either set may defer, skip, or report a broken
    # resource; all-or-nothing commitment is preserved because we
    # only call assign() in _launch_job after the entire walk returns
    # ('launch', \@use).
    #
    # Return shape: ('launch', \@use)
    #               ('defer')
    #               ('skip', $resource_name)
    #                          - resource is present but can never
    #                            grant THIS specific job (e.g. job's
    #                            min_slots exceeds the resource's
    #                            per-job cap). Scheduler routes the
    #                            job through the unavailable-action
    #                            skip launch so the user sees a real
    #                            skip_all event and the run still
    #                            completes; other jobs that fit the
    #                            cap continue to use the resource.
    #               ('broken', $resource_name)
    #                          - a needed resource has been flipped
    #                            to permanent_broken. Scheduler
    #                            consults broken_resource_behavior
    #                            to decide skip / fail / abort.
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});

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


sub _ensure_run_service_started {
    my ($self, $run) = @_;

    # Method name is historical: the run service no longer exists
    # (Stage 9 of the RunService flatten). The hook still owns the
    # one-time per-run bring-up: writing the run's spec.jsonl and
    # spawning per-run resource services. The resources_started /
    # resources_torn_down flags on Run::State guard idempotency.
    my $rstate = $self->{+RUN_STATES}->{$run->run_id} //=
        Test2::Harness2::Run::State->new(run_id => $run->run_id);
    return if $rstate->resources_started_flag;
    $rstate->mark_resources_started;

    # Always write the run-level spec.jsonl, even when ipcm_info is
    # undef (unit-test path) -- downstream tooling reads it from
    # disk regardless of whether the harness has an IPC bus.
    $self->_write_run_spec($run);

    # In unit tests that exercise scheduler logic without building
    # a real IPC bus, ipcm_info is undef; skip the resource spawn
    # then so the rest of the scheduler still works.
    return unless defined $self->ipcm_info;

    my $run_id = $run->run_id;

    # Bring up the run's resource services. They run as direct
    # children of the harness, so signal/kill propagation is
    # uniform with the global resources hosted here, and the
    # per-run pid bookkeeping in RUN_PIDS captures them via the
    # host-role tracking hooks. The harness has already validated
    # the resource set (needed + non-permanent) before taking this
    # branch.
    my $resources = $run->resources // [];
    if (@$resources) {
        my $rs_ok = eval {
            $self->start_resource_services($resources, scope => 'run', run => $run);
            1;
        };
        unless ($rs_ok) {
            my $err = $@;
            warn "Test2::Harness2: per-run resource services for '$run_id' failed to start: $err\n";
        }
    }

    return;
}

# Run-level artifact trio written at run start. spec.jsonl is the
# single-row JSON document downstream tooling (App::Yath2 Log
# readers, archive layout, DB importer) anchors on; events.jsonl
# and report.jsonl exist as empty placeholders so the per-run
# directory shape matches what the Run-type collector used to
# produce. Renderers no longer descend into the per-run events
# stream (no harness_collector_start of type=Run is emitted), but
# tooling that lists artifacts still expects all three to exist.
sub _write_run_spec {
    my ($self, $run) = @_;

    my $run_id = $run->run_id;
    my $dir    = "$self->{+LOGDIR}/runs/$run_id";
    File::Path::make_path($dir) unless -d $dir;

    my $spec_path = "$dir/spec.jsonl";
    unless (-e $spec_path) {
        my %spec = (
            run_id   => $run_id,
            run_uuid => $run->run_uuid,
            name     => 'run',
            harness  => $self->{+NAME},
        );
        open my $fh, '>', $spec_path or croak "open '$spec_path': $!";
        print $fh encode_json(\%spec), "\n";
        close $fh;
    }

    for my $base (qw/events.jsonl report.jsonl/) {
        my $path = "$dir/$base";
        next if -e $path;
        open my $fh, '>>', $path or croak "open '$path': $!";
        close $fh;
    }

    return;
}

# Write the per-run report.jsonl with the collector_report
# aggregate built from RUN_FLAGS at finalize time. Mirrors the
# RunService write_phase that the deleted Run-type collector used
# to do. Single-row JSON document, same shape as the harness-side
# emit_run_completed payload's collector_report facet.
sub _write_run_report {
    my ($self, $run) = @_;

    my $run_id = $run->run_id;
    my $dir    = "$self->{+LOGDIR}/runs/$run_id";
    File::Path::make_path($dir) unless -d $dir;

    my $path   = "$dir/report.jsonl";
    my $report = $self->_build_collector_report($run, time);

    open my $fh, '>', $path or croak "open '$path': $!";
    print $fh encode_json($report), "\n";
    close $fh;
    return;
}

sub _teardown_run_service {
    my ($self, $run) = @_;

    # Method name is historical: there is no run service to
    # signal anymore (Stage 9 of the RunService flatten). What
    # this hook now does is run the per-run resource teardown
    # cascade: invoke each resource's teardown method so
    # in-process cleanup runs, then TERM every pid still
    # registered to this run via RUN_PIDS so resource services
    # exit. The Run::State idempotency flag prevents double
    # teardown for the same run.
    my $rid    = $run->run_id;
    my $rstate = $self->{+RUN_STATES}->{$rid};
    return                            if $rstate && $rstate->resources_torn_down_flag;
    $rstate->mark_resources_torn_down if $rstate;

    for my $res (@{$run->resources // []}) {
        my $tok  = eval { $res->teardown; 1 };
        my $terr = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $terr"
            unless $tok;
    }
    $self->{+PID_INDEX}->kill_run($rid, 'TERM');

    return;
}

sub _launch_job {
    my ($self, $run, $job, $resources, %opts) = @_;

    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    # The resolver hands us the Resource::Preload to route this job
    # through (when one was requested). Append it to the assigned-
    # resources list so the standard release-on-cleanup path handles
    # its assign/release lifecycle (even though Resource::Preload's
    # assign/release are no-ops).
    my $preload_resource = delete $opts{preload_resource};
    $resources = [@$resources, $preload_resource] if defined $preload_resource;

    $self->_announce_run_started_if_first($run_id);

    my $assign_id   = gen_uuid();
    my %assign_args = %{$opts{assign_args} // {}};
    my %env         = $self->_build_launch_env($run);
    for my $res (@$resources) {
        $res->assign(id => $assign_id, job => $job, env => \%env, %assign_args);
    }

    # ch_dir priority: run-level --chdir > per-test ch_dir (Finder) > none.
    my $ch_dir = $run->chdir // $job->test_file->ch_dir;

    my $launch_ok = eval {
        if (defined $preload_resource) {
            $self->_spawn_via_preload(
                $run, $job, $preload_resource,
                env                => \%env,
                assign_id          => $assign_id,
                assigned_resources => $resources,
                (defined $opts{launch} ? (launch => $opts{launch}) : ()),
                (defined $ch_dir       ? (ch_dir => $ch_dir)       : ()),
            );
            $self->_scheduler_mark_running($run_id, $job_id);
            return 1;
        }

        $self->_launch_collector_inline(
            $run, $job, $resources,
            assign_id => $assign_id,
            env       => \%env,
            (defined $opts{launch} ? (launch => $opts{launch}) : ()),
            (defined $ch_dir       ? (ch_dir => $ch_dir)       : ()),
        );
        1;
    };
    my $launch_err = $@;

    unless ($launch_ok) {
        # Launch failed; release the resources we just committed so
        # their slots don't leak. The job never reached RUNNING_JOBS
        # so _release_job_resources won't reach it on its own.
        for my $res (@$resources) {
            my $rok  = eval { $res->release(id => $assign_id, job => $job); 1 };
            warn "failed to release resource '" . $res->resource_name . "' after launch failure: $@"
                unless $rok;
        }
        die $launch_err;
    }

    return $job_id;
}

# First job of this run: emit run_started and stamp started_at.
# Renderer::Driver's lifecycle synthesizer reads the flat run_id /
# started_at fields off the harness facet to stamp
# run_states->{$rid}{started_at}.
sub _announce_run_started_if_first {
    my ($self, $run_id) = @_;
    return if $self->_scheduler_started($run_id);

    my $started_at = time;
    $self->emit_service_event(
        kind       => 'run_started',
        run_id     => $run_id,
        started_at => $started_at,
    );
    $self->_run_flags($run_id)->{started_at} //= $started_at;
}

# Build the base env hash for a launched test child. Forwards
# T2_HARNESS_INCLUDES so callers can inject @INC paths without per-test
# CLI flags. Propagates the run's --set-hash-seed value as
# PERL_HASH_SEED when present.
sub _build_launch_env {
    my ($self, $run) = @_;

    my %env;
    $env{T2_HARNESS_INCLUDES} = $ENV{T2_HARNESS_INCLUDES}
        if defined $ENV{T2_HARNESS_INCLUDES} && length $ENV{T2_HARNESS_INCLUDES};

    my $hash_seed = $run->hash_seed;
    $env{PERL_HASH_SEED} = $hash_seed if defined $hash_seed && length $hash_seed;

    return %env;
}

# Direct (no-preload) launch path: harness owns the collector fork,
# the test is its grandchild, and the reap lands at run_on_pid. Calls
# the inline collector spawn helper, registers the running job, and
# bumps in-flight bookkeeping. Dies on spawn failure so the caller's
# resource-rollback path runs.
sub _launch_collector_inline {
    my ($self, $run, $job, $resources, %opts) = @_;

    my $run_id    = $run->run_id;
    my $job_id    = $job->job_id;
    my $assign_id = delete $opts{assign_id};
    my $env       = delete $opts{env};

    my $resp = $self->_spawn_collector_for_job(
        $run, $job,
        env => $env,
        (defined $opts{launch} ? (launch => $opts{launch}) : ()),
        (defined $opts{ch_dir} ? (ch_dir => $opts{ch_dir}) : ()),
    );
    die "collector spawn returned no pid"
        unless ref($resp) eq 'HASH' && $resp->{ok} && $resp->{pid};

    $self->_scheduler_mark_running($run_id, $job_id);

    my $started_at = time;
    $self->{+RUNNING_JOBS}->{$job_id} = {
        run                => $run,
        job                => $job,
        pid                => $resp->{pid},
        started_at         => $started_at,
        assign_id          => $assign_id,
        assigned_resources => $resources,
        log_file           => $resp->{log_file},
    };
    $self->{+IN_FLIGHT_COUNT}++;

    $self->{+PID_INDEX}->register(
        $run_id, $resp->{pid},
        kind       => 'collector',
        job_id     => $job_id,
        job_try    => $job->job_try,
        started_at => $started_at,
    );

    return;
}

# Build the Collector spawn args + invoke Collector->spawn directly,
# without going through the RunService IPC. Inlined from the body of
# RunService::request_handler_launch_job. Returns the same shape:
# {ok => 1, pid => $collector_pid, log_file => undef} or
# {ok => 0, error => "..."}.
sub _spawn_collector_for_job {
    my ($self, $run, $job, %opts) = @_;

    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;
    my $job_try = $job->job_try // 1;

    my $env     = $opts{env} // {};
    my $launch  = $opts{launch};
    my $ch_dir  = $opts{ch_dir};
    my $auditor = $opts{auditor} // $self->{+TEST_AUDITOR};

    my $test_file_abs = $job->test_file_abs;
    return {ok => 0, error => "'test_file' must be absolute"}
        unless File::Spec->file_name_is_absolute($test_file_abs);

    # The unavailable-action skip / fail paths hand us an explicit
    # launch command (perl -e '...'). Default to running the real
    # test file when no override is present. Forward T2_HARNESS_INCLUDES
    # as -I flags so the child interpreter actually picks the paths up.
    if (!defined $launch) {
        my @extra_inc;
        if (my $inc = $env->{T2_HARNESS_INCLUDES}) {
            @extra_inc = grep { length && $_ ne '.' } split /;/, $inc;
        }
        $launch = [$^X, (map { "-I$_" } @extra_inc), '-Ilib', $test_file_abs];
    }

    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    # queued_at on the per-job spec.jsonl artifact: pull from
    # Run::State so the renderer sees the queue-time stamp.
    my $queued_at;
    if (my $rs = $self->{+RUN_STATES}->{$run_id}) {
        my $r = $rs->results->{$job_id};
        $queued_at = $r->{queued_at} if $r && defined $r->{queued_at};
    }

    my $handle;
    my $spawn_ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            type         => 'Job',
            id           => $job_id,
            run_id       => $run_id,
            job_try      => $job_try,
            launch       => $launch,
            new_pgroup   => 1,
            parent_pids  => [$$],
            env_vars     => {T2_FORMATTER => 'Stream2', %$env},
            (defined $ch_dir && length $ch_dir ? (cwd => $ch_dir) : ()),
            logdir       => $self->{+LOGDIR},
            ipcm_info    => $self->ipcm_info,
            ipc_parent   => $self->{+NAME},
            ipc_run      => $self->{+NAME},
            ipc_harness  => $self->{+NAME},
            kill_timeout => $self->{+KILL_TIMEOUT},
            spec         => {
                %{$test_file_spec->TO_JSON},
                run_id  => $run_id,
                job_id  => $job_id,
                job_try => $job_try,
                (defined $queued_at ? (queued_at => $queued_at) : ()),
            },
            (defined $auditor ? (auditor => $auditor) : ()),
        );
        1;
    };
    return {ok => 0, error => "collector spawn failed: $@"}
        unless $spawn_ok;

    my $pid = $handle->pid;
    return {ok => 1, pid => $pid, log_file => undef};
}

# Async spawn through a preload service. The preload service owns the
# fork: pre_fork hook, fork, post_fork hook, second fork, _exit(0) in
# the middle layer, grandchild runs the test (after Long::Jump +
# goto::file).
#
# Records a placeholder RUNNING_JOBS entry with pid=>undef; the
# grandchild's auditor lands a test_job_started which the harness's
# _handle_test_job_started uses to fill in the real pid and register
# the collector pid in RUN_PIDS. PENDING_SPAWN_REQUESTS tracks the
# in-flight request for timeout protection (run_on_interval ages them
# and flips the preload to is_broken if the watchdog fires).
sub _spawn_via_preload {
    my ($self, $run, $job, $preload_resource, %opts) = @_;

    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;
    my $job_try = $job->job_try // 1;

    my $test_file_abs = $job->test_file_abs;
    croak "'test_file' must be absolute"
        unless File::Spec->file_name_is_absolute($test_file_abs);

    my $now = time;
    $self->_register_pending_preload_spawn($run, $job, $preload_resource, $now, \%opts);

    my $payload = $self->_build_spawn_test_payload($run, $job, $test_file_abs, \%opts);
    my $peer    = _preload_peer_name($preload_resource);

    my $send_ok = eval { $self->client->send_message($peer, $payload); 1 };
    unless ($send_ok) {
        my $send_err = $@;
        # Roll back so the caller's launch_failed path (which releases
        # assigned resources) can take over cleanly.
        delete $self->{+RUNNING_JOBS}->{$job_id};
        delete $self->{+PENDING_SPAWN_REQUESTS}->{"$run_id\0$job_id"};
        croak "Failed to dispatch spawn_test to '$peer': $send_err";
    }

    return;
}

sub _register_pending_preload_spawn {
    my ($self, $run, $job, $preload_resource, $now, $opts) = @_;
    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    $self->{+RUNNING_JOBS}->{$job_id} = {
        run                  => $run,
        job                  => $job,
        pid                  => undef,
        awaiting_preload_pid => 1,
        preload_name         => $preload_resource->name,
        preload_scope        => $preload_resource->scope,
        started_at           => $now,
        assign_id            => $opts->{assign_id},
        assigned_resources   => $opts->{assigned_resources} // [],
        log_file             => undef,
    };

    $self->{+PENDING_SPAWN_REQUESTS}->{"$run_id\0$job_id"} = {
        run_id        => $run_id,
        job_id        => $job_id,
        sent_at       => $now,
        preload_name  => $preload_resource->name,
        preload_scope => $preload_resource->scope,
    };
}

sub _build_spawn_test_payload {
    my ($self, $run, $job, $test_file_abs, $opts) = @_;
    my $run_id  = $run->run_id;
    my $job_id  = $job->job_id;
    my $job_try = $job->job_try // 1;
    my $env     = $opts->{env}    // {};
    my $launch  = $opts->{launch};
    my $ch_dir  = $opts->{ch_dir};

    my $test_file_spec = Test2::Harness2::TestFile->new(file => $test_file_abs);

    my $queued_at;
    if (my $rs = $self->{+RUN_STATES}->{$run_id}) {
        my $r = $rs->results->{$job_id};
        $queued_at = $r->{queued_at} if $r && defined $r->{queued_at};
    }

    return {
        kind          => 'spawn_test',
        run_id        => $run_id,
        job_id        => $job_id,
        job_try       => $job_try,
        test_file_abs => $test_file_abs,
        env           => {T2_FORMATTER => 'Stream2', %$env},
        auditor       => $self->{+TEST_AUDITOR},
        ipc_parent    => $self->{+NAME},
        ipc_run       => $self->{+NAME},
        ipc_harness   => $self->{+NAME},
        kill_timeout  => $self->{+KILL_TIMEOUT},
        logdir        => $self->{+LOGDIR},
        spec          => {
            %{$test_file_spec->TO_JSON},
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job_try,
            (defined $queued_at ? (queued_at => $queued_at) : ()),
        },
        (defined $launch ? (launch => $launch) : ()),
        (defined $ch_dir && length $ch_dir ? (ch_dir => $ch_dir) : ()),
    };
}

# Walk PENDING_SPAWN_REQUESTS; for any entry past
# preload_spawn_timeout_secs without a matching test_job_started,
# release the placeholder, flag the preload transient broken, and
# bounce the job back to pending so the next scheduler tick can
# re-attempt (either through the same preload once it recovers, or
# through a fallback path in the preference list).
sub _age_pending_spawn_requests {
    my $self = shift;

    my $pending = $self->{+PENDING_SPAWN_REQUESTS};
    return unless $pending && keys %$pending;

    my $timeout = $self->{+PRELOAD_SPAWN_TIMEOUT_SECS} || 30;
    my $now     = time;

    for my $key (keys %$pending) {
        my $entry = $pending->{$key};
        next if ($now - $entry->{sent_at}) < $timeout;

        my $run_id = $entry->{run_id};
        my $job_id = $entry->{job_id};

        # If the auditor's test_job_started already populated the
        # RUNNING_JOBS entry's pid we missed the cleanup; drop the
        # pending row and move on.
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        if (!$cur || !$cur->{awaiting_preload_pid}) {
            delete $pending->{$key};
            next;
        }

        warn sprintf(
            "Test2::Harness2: spawn_test request to preload '%s' (%s scope) for job %s timed out after %ds\n",
            $entry->{preload_name}, $entry->{preload_scope}, $job_id, $timeout,
        );

        # Flip the resource to transient broken so the next resolver
        # call defers or routes elsewhere.
        for my $res (@{$self->{+RESOURCES} // []}) {
            next unless blessed($res) && $res->isa('Test2::Harness2::Resource::Preload');
            next unless $res->name  eq $entry->{preload_name};
            next unless $res->scope eq $entry->{preload_scope};
            $res->mark_broken;
            last;
        }

        # Release any committed limiters (jobcount etc.) and drop the
        # placeholder, then return the job to pending so the
        # scheduler picks it up next tick.
        $self->_release_job_resources($cur);
        delete $self->{+RUNNING_JOBS}->{$job_id};
        $self->_scheduler_mark_pending($run_id, $job_id);
        delete $pending->{$key};
    }

    return;
}

# Derive the bus name the harness uses to talk to a PreloadService
# instance. Mirrors PreloadService's name derivation: preload-<n> for
# global, preload-<run_id>-<n> for run scope. Keeping the rule in one
# place keeps the resolver-side and spawn-side wiring honest.
sub _preload_peer_name {
    my ($res) = @_;
    my $n = $res->name;
    return "preload-$n" if $res->scope eq 'global';
    my $rid = $res->run->run_id;
    return "preload-$rid-$n";
}

# Deterministic peer name for a resource service spawned via preload.
# Format mirrors _preload_peer_name: resource-<n> for global scope,
# resource-<run_id>-<n> for run scope. The harness uses this so the
# grandchild (which only sees the payload) can register under the
# expected name without round-tripping through this helper.
sub _resource_peer_name {
    my ($self, $entry) = @_;
    my $n     = $entry->{name};
    my $scope = $entry->{scope} // 'global';
    return "resource-$n" if $scope eq 'global';
    my $rid = $entry->{run};
    $rid = $rid->run_id if ref($rid) && $rid->can('run_id');
    return "resource-$n" unless defined $rid && length $rid;
    return "resource-$rid-$n";
}

# Look up a live, global-scope, not-permanent_broken PreloadService
# whose underlying resource.name matches $pname. Returns the
# resource_services entry hash or undef. Initial design covers
# global-scope preloads only; run-scoped reuse is a follow-up.
sub _find_eligible_preload_service {
    my ($self, $pname) = @_;
    return undef unless defined $pname && length $pname;

    for my $info (values %{ $self->{+RESOURCE_SERVICES} // {} }) {
        next unless ($info->{service_class} // '') eq 'Test2::Harness2::PreloadService';
        next unless ($info->{scope}         // '') eq 'global';
        my $res = $info->{resource};
        next unless ref($res) && $res->can('name');
        next unless $res->name eq $pname;
        next if $res->can('is_permanent_broken') && $res->is_permanent_broken;
        next unless defined $info->{pid} && kill 0 => $info->{pid};
        return $info;
    }
    return undef;
}

# Send a spawn_service message to the named PreloadService and install
# a pending entry the resource_service_started handler will finalize.
# Returns the allocated spawn_id on dispatch success, undef on send
# failure (caller's _start_service_entry falls back to standalone).
#
# Distinct from _spawn_via_preload (which spawns test-job collectors
# through a PreloadService): this one spawns a *resource service*
# (e.g. another PreloadService, or any Role::Service implementor) by
# asking an already-running PreloadService to fork it for us. The
# split keeps the two payload shapes ('spawn_test' vs 'spawn_service')
# from sharing state and pending-table semantics.
sub _spawn_service_via_preload {
    my ($self, $preload_info, $entry) = @_;

    my $spawn_id  = ++$self->{_PRELOAD_SPAWN_COUNTER};
    my $peer_name = $self->_resource_peer_name($entry);

    # The resource_services tracking entry keys the service under the
    # name extracted from its ctor args (e.g. 'myapp' for a
    # Resource::Preload-spawned PreloadService). That is NOT the IPC
    # bus name -- PreloadService advertises itself as 'preload-<name>'
    # (or 'preload-<run_id>-<name>' for run scope). Send to the bus
    # name, not the tracking name, or the message is rejected as
    # "not a valid message recipient".
    my $preload_bus_name = _preload_peer_name($preload_info->{resource});

    $self->{+PENDING_PRELOAD_SPAWNS}->{$spawn_id} = {
        entry        => $entry,
        peer_name    => $peer_name,
        preload_pid  => $preload_info->{pid},
        preload_name => $preload_bus_name,
        sent_at      => time,
    };

    my $client = $self->client;
    my $ok = eval {
        $client->send_message($preload_bus_name, {
            kind      => 'spawn_service',
            class     => $entry->{service_class},
            peer_name => $peer_name,
            ctor_args => do {
                my $ca = { %{ $entry->{service_args} // {} } };
                my $wp = $ca->{watch_pids} // [];
                $wp = [$wp] unless ref($wp) eq 'ARRAY';
                $ca->{watch_pids} = [ @$wp, $self->pid ];
                $ca;
            },
            notify_to => $self->name,
            spawn_id  => $spawn_id,
        });
        1;
    };
    my $err = $@;

    unless ($ok) {
        delete $self->{+PENDING_PRELOAD_SPAWNS}->{$spawn_id};
        warn "Test2::Harness2: preload spawn dispatch to '$preload_bus_name' failed: $err\n";
        return undef;
    }

    return $spawn_id;
}

# Handle a 'spawn_script' request from a CLI client. Thin shim that
# delegates to Test2::Harness2::SpawnGateway, which owns the SCM_RIGHTS
# pathway state and helpers.
sub request_handler_spawn_script {
    my $self = shift;
    return $self->{+SPAWN_GATEWAY}->handle_request(@_);
}

# Finalize a preload-mediated resource spawn. The grandchild's
# notification carries pid + spawn_id; we look up the pending entry,
# clear it, and register the new pid in resource_services via
# track_resource_service. Emits resource_spawn_via_preload for
# operator visibility.
sub _handle_resource_service_started {
    my ($self, $content) = @_;

    return unless $content->{via_preload};

    my $sid = $content->{spawn_id};
    return unless defined $sid;

    my $pending = delete $self->{+PENDING_PRELOAD_SPAWNS}->{$sid}
        or return;    # unknown / stale spawn_id

    my $entry = $pending->{entry};
    my $pid   = $content->{pid};

    my $args_ref = ref($entry->{service_args}) eq 'HASH'
        ? [%{$entry->{service_args}}]
        : ($entry->{service_args} // []);

    # Track under the bus peer name ('resource-myappservice') so the
    # human-facing `yath ps` / `yath resources` output continues to show
    # the IPC peer name. Carry the raw entry name as `entry_name` so the
    # restart path (handle_resource_service_exit -> _start_service_entry)
    # can rebuild the bus name through _resource_peer_name without
    # double-prefixing into 'resource-resource-myappservice' on every
    # restart cycle.
    $self->track_resource_service(
        pid           => $pid,
        resource      => $entry->{resource},
        service_class => $entry->{service_class},
        service_args  => $args_ref,
        name          => $pending->{peer_name},
        entry_name    => $entry->{name},
        log_path      => $entry->{log_path},
        scope         => $entry->{scope},
        (defined $entry->{run} ? (run => $entry->{run}) : ()),
        started_at    => time,
        attempts      => $entry->{attempts} // 1,
        via_preload   => 1,
    );

    $self->emit_service_event(
        kind          => 'resource_spawn_via_preload',
        resource      => (ref($entry->{resource}) && $entry->{resource}->can('resource_name')
                          ? $entry->{resource}->resource_name : '?'),
        service_class => $entry->{service_class},
        name          => $pending->{peer_name},
        scope         => $entry->{scope} // 'global',
        preload_name  => $pending->{preload_name},
        preload_pid   => $pending->{preload_pid},
        pid           => $pid,
        spawn_id      => $sid,
    );

    return;
}

# Drain the wait-for-preload queue for $pname through
# _spawn_service_via_preload. Called from _handle_preload_state_message
# when preload_ready arrives, after the matching Resource::Preload has
# been flipped to ready. If for some reason the preload is no longer
# eligible by the time we reach here (raced with permanent_broken,
# etc.) the entries fall back to standalone with a fallback event.
sub _drain_resources_awaiting_preload {
    my ($self, $pname) = @_;
    return unless defined $pname && length $pname;

    my $queue = delete $self->{+RESOURCES_AWAITING_PRELOAD}->{$pname};
    return unless ref($queue) eq 'ARRAY' && @$queue;

    my $preload_info = $self->_find_eligible_preload_service($pname);
    for my $entry (@$queue) {
        if ($preload_info) {
            $self->_spawn_service_via_preload($preload_info, $entry);
        }
        else {
            $self->_fallback_single_entry($entry, $pname, 'preload not eligible at drain time');
        }
    }
    return;
}

# Flush the wait-for-preload queue for $pname through
# _ipcm_service_standalone. Called when the preload reports
# permanent_broken: the dependents still come up, just unpreloaded.
sub _fallback_resources_awaiting_preload {
    my ($self, $pname) = @_;
    return unless defined $pname && length $pname;

    my $queue = delete $self->{+RESOURCES_AWAITING_PRELOAD}->{$pname};
    return unless ref($queue) eq 'ARRAY' && @$queue;

    for my $entry (@$queue) {
        $self->_fallback_single_entry($entry, $pname, 'preload permanent_broken');
    }
    return;
}

# Helper: emit the fallback event for one queued entry and re-dispatch
# it through _ipcm_service_standalone. Shared between the drain and
# fallback paths so the event shape stays consistent.
sub _fallback_single_entry {
    my ($self, $entry, $pname, $reason) = @_;

    my $res = $entry->{resource};
    $self->emit_service_event(
        kind          => 'resource_spawn_preload_fallback',
        resource      => (ref($res) && $res->can('resource_name')
                          ? $res->resource_name : '?'),
        service_class => $entry->{service_class},
        name          => $entry->{name},
        scope         => $entry->{scope} // 'global',
        preload_name  => $pname,
        reason        => $reason,
    );

    my $args = ref($entry->{service_args}) eq 'HASH'
        ? [%{$entry->{service_args}}]
        : ($entry->{service_args} // []);

    $self->_ipcm_service_standalone(
        resource => $res,
        class    => $entry->{service_class},
        args     => $args,
        name     => $entry->{name},
        log_path => $entry->{log_path},
        scope    => $entry->{scope} // 'global',
        (defined $entry->{run} ? (run => $entry->{run}) : ()),
    );

    return;
}

# Walk PENDING_PRELOAD_SPAWNS, drop entries older than
# PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS, and re-dispatch via standalone.
# Closes the gap where a grandchild fails to start before sending its
# resource_service_started notification (compile error, fork issue,
# killed before notify, etc.). Called from run_on_interval each tick.
sub _check_pending_preload_spawn_timeouts {
    my $self = shift;

    my $pending  = $self->{+PENDING_PRELOAD_SPAWNS} // {};
    my $deadline = $self->{+PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS} // 30;
    my $now      = time;

    for my $sid (keys %$pending) {
        my $p = $pending->{$sid};
        next if $now - ($p->{sent_at} // $now) < $deadline;

        delete $pending->{$sid};

        my $entry = $p->{entry};
        my $res   = $entry->{resource};

        $self->emit_service_event(
            kind          => 'resource_spawn_preload_timeout',
            resource      => (ref($res) && $res->can('resource_name') ? $res->resource_name : '?'),
            service_class => $entry->{service_class},
            name          => $entry->{name},
            scope         => $entry->{scope} // 'global',
            preload_name  => $p->{preload_name},
            spawn_id      => $sid,
            reason        => "no notification within ${deadline}s",
        );

        my $args = ref($entry->{service_args}) eq 'HASH'
            ? [%{$entry->{service_args}}]
            : ($entry->{service_args} // []);

        $self->_ipcm_service_standalone(
            resource => $res,
            class    => $entry->{service_class},
            args     => $args,
            name     => $entry->{name},
            log_path => $entry->{log_path},
            scope    => $entry->{scope} // 'global',
            (defined $entry->{run} ? (run => $entry->{run}) : ()),
        );
    }

    return;
}

1;

__END__

=head1 NAME

Test2::Harness2 - Top-level test harness service.

=head1 SYNOPSIS

    # Run once, then exit
    Test2::Harness2->start(
        workdir                  => '/path/to/wd',
        test_run                 => {files => ['t/a.t', 't/b.t']},
        finish_after_initial_run => 1,
    );

    # Spawn as a persistent daemon, keep queuing
    my $spawn = Test2::Harness2->spawn(workdir => '/path/to/wd');
    $spawn->queue_test_run(files => ['t/c.t']);
    my $status = $spawn->status;
    $spawn->finish;
    $spawn->wait;

=head1 DESCRIPTION

B<Use start() or spawn(), not new().> Direct C<new()> constructs the object
but does not start the service loop. Prefer the C<start()> entry point when
you want the current process to become the harness, or C<spawn()> when you
want the harness to run in a child process and get back a handle to it.

=head1 JUMP_TO

Passing C<jump_to =E<gt> $name> to C<start()> tells the harness to unwind
its own call stack inside the interposed collector child before running the
service, using L<Long::Jump>. The caller must install a matching
C<setjump()> around the C<start()> call; when the longjump fires the
setjump returns a single-element arrayref whose only element is a
coderef. Invoking that coderef runs the service (set up the emitter, queue
any requested run, enter the main loop, and C<_exit>).

This is useful when a test script has deep harness machinery above the
setjump that should not be present on the service's stack. After the jump,
the service runs from a clean stack frame, so exceptions and stack traces
are tidier and an accidental C<return> out of the service cannot resume
execution anywhere unintended.

    use Long::Jump qw/setjump/;

    my $ret = setjump 'harness' => sub {
        Test2::Harness2->start(
            workdir => $wd,
            jump_to => 'harness',
            # ... other start() args ...
        );
        # unreachable in the service child; the parent becomes the
        # collector and exits without returning here either.
    };

    my ($run_service) = @$ret;
    $run_service->();   # never returns; service calls _exit

If C<jump_to> is set but no matching setjump is active, C<start()> croaks
before forking. Without C<jump_to>, C<start()> behaves exactly as before.

=head1 METHODS

This section documents the internal subroutines added by the preload-as-resource
rework. Most are (internal) helpers invoked by the IPC service loop, the
scheduler, or the various C<request_handler_*> entry points. They are listed
here so the implementation reads coherently, not because external callers should
invoke them.

=head2 Preload resolution

=head2 _resolve_preload_for_job

(internal) For C<($run, $job)>, walks the job's C<preload_preferences> against
the per-run preload index and returns C<($resource, $kind, $extra)>. C<$kind>
is one of C<no_preload>, C<preload>, C<defer>, or C<broken>.

=head2 _index_preloads_for_run

(internal) Builds C<{ by_global, by_run, global_default, run_default }> for a
run, picking out L<Test2::Harness2::Resource::Preload> instances visible to it.

=head2 _classify_preload_state

(internal) Maps a L<Test2::Harness2::Resource::Preload> to one of
C<permanent>, C<usable>, or C<defer>.

=head2 Run setup

=head2 _init_logdir

(internal) Resolves the harness's C<logdir> relative to the workdir
(absolute paths are used verbatim), refuses to clobber a non-empty
existing directory, and creates the C<services/> subdirectory.

=head2 _init_default_slots

(internal) Mass-defaulter for the harness's scalar/hash/array slots
(name, job_id, queue, scheduler, pending-* maps, etc.). Keeps
L</init> short by collecting every slot whose default does not
depend on validation.

=head2 _strip_legacy_logger_slots

(internal) Deletes the legacy C<loggers> / C<service_loggers> /
C<test_loggers> / C<extend_loggers> / C<extend_test_loggers>
constructor args so old callers do not crash; the collector now
writes its on-disk artifacts directly.

=head2 _validate_run_hash_seed

(internal) Returns an error string if the run's C<--set-hash-seed> conflicts
with the harness's, or C<undef> when compatible.

=head2 _rehydrate_run_resources

(internal) Constructs per-run L<Test2::Harness2::Resource> instances from the
IPC-recipe form C<[ [class, @ctor_args], ... ]>. Returns C<(1, \@instances)>
on success or C<(0, $error)> on failure.

=head2 Request handlers

=head2 request_handler_list_preloads

Returns C<{ ok =E<gt> 1, preloads =E<gt> \@list }> describing every live,
global-scope L<Test2::Harness2::PreloadService>. Used by C<yath ps> /
C<yath spawn>.

=head2 request_handler_abort_run

Latches a C<user_abort> reason onto one run (C<run_id>) or all runs (C<all>).
Pending jobs flow through the existing unavailable-action path; running jobs
are left alone.

=head2 request_handler_spawn_script

Handles C<yath spawn>. Thin shim that delegates to
L<Test2::Harness2::SpawnGateway>, which owns the SCM_RIGHTS pathway state
and helpers.

=head2 IPC message handlers

=head2 _handle_preload_state_message

(internal) Applies C<preload_ready> / C<preload_broken> messages to the
matching L<Test2::Harness2::Resource::Preload>, then drains or falls back any
dependent resource services queued under L</_drain_resources_awaiting_preload>
/ L</_fallback_resources_awaiting_preload>.

=head2 _handle_test_collector_exit

(internal) Bridges a reaped test-collector pid to the run service. Either
forgets the pid (when the run service has already accepted completion) or
records a pending synthetic completion the watchdog can flush.

=head2 _handle_resource_service_started

(internal) Finalizes a preload-mediated resource spawn: registers the new pid
under the bus peer name and emits C<resource_spawn_via_preload>.

=head2 Scheduler

=head2 _scheduler_mark_pending

(internal) Pushes C<$job_id> back into the run's pending queue and clears it
from C<running>, used when a deferred / timed-out launch needs to be retried.

=head2 _dispatch_pending_job

(internal) Per-job dispatch decision used by C<_try_launch_next_pending>.
Combines the run-aborted short-circuit, the preload resolver, and the generic
resource evaluator, returning C<'launched'>, C<'defer'>, or C<'skipped'>.

=head2 Launch helpers

=head2 _announce_run_started_if_first

(internal) Emits the one-shot C<run_started> service event and stamps
C<started_at> the first time a run actually launches a job.

=head2 _build_launch_env

(internal) Builds the base C<%env> for a launched test child: forwards
C<T2_HARNESS_INCLUDES> and propagates the run's hash seed via
C<PERL_HASH_SEED>.

=head2 _launch_collector_inline

(internal) Direct (no-preload) launch path. Spawns the collector via
L</_spawn_collector_for_job>, registers the C<RUNNING_JOBS> entry, bumps
in-flight bookkeeping, and records the collector pid under the run.

=head2 _spawn_via_preload

(internal) Async test-job launch through a preload service. Registers a
placeholder C<RUNNING_JOBS> entry, sends the C<spawn_test> payload, and arms
the timeout watchdog (see L</_age_pending_spawn_requests>).

=head2 _register_pending_preload_spawn / _build_spawn_test_payload

(internal) Helpers for L</_spawn_via_preload>: the first installs the
placeholder and tracking row, the second builds the C<spawn_test> payload sent
to the preload bus peer.

=head2 _age_pending_spawn_requests

(internal) Per-tick watchdog for in-flight C<spawn_test> requests. Times out
stale entries, flips the preload to transient broken, releases held resources,
and returns the job to pending.

=head2 Preload / resource peer naming

=head2 _preload_peer_name / _resource_peer_name

(internal) Deterministic bus names for L<Test2::Harness2::PreloadService>
peers and preload-spawned resource services. Global scope yields
C<preload-NAME> / C<resource-NAME>; run scope adds the run id between the
prefix and the name.

=head2 Preload-spawned resource services

=head2 _find_eligible_preload_service

(internal) Returns the C<resource_services> tracking entry for a live,
global-scope, not-C<permanent_broken> L<Test2::Harness2::PreloadService>
whose underlying resource matches C<$pname>, or C<undef>.

=head2 _spawn_service_via_preload

(internal) Sends a C<spawn_service> message to a preload service and records a
C<PENDING_PRELOAD_SPAWNS> row that L</_handle_resource_service_started>
finalizes. Returns the allocated spawn id on dispatch success, C<undef> on
send failure.

=head2 _drain_resources_awaiting_preload

(internal) Drains the wait-for-preload queue for a stage through
L</_spawn_service_via_preload> once the preload becomes ready. Entries that
are no longer eligible fall through to L</_fallback_single_entry>.

=head2 _fallback_resources_awaiting_preload

(internal) Flushes the same queue through standalone spawn when the preload
reports C<permanent_broken>; dependents still come up, just unpreloaded.

=head2 _fallback_single_entry

(internal) Emits the C<resource_spawn_preload_fallback> event and
re-dispatches one queued entry via C<_ipcm_service_standalone>; shared by both
the drain and fallback paths.

=head2 _check_pending_preload_spawn_timeouts

(internal) Per-tick watchdog for C<PENDING_PRELOAD_SPAWNS>. Drops entries
older than C<PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS> and re-dispatches them via
standalone spawn, emitting C<resource_spawn_preload_timeout>.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
