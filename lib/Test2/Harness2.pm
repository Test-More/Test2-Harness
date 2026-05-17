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
use Test2::Harness2::JobTracker;
use Test2::Harness2::PidIndex;
use Test2::Harness2::PreloadRouter;
use Test2::Harness2::RunStates;
use Test2::Harness2::Scheduler;
use Test2::Harness2::SpawnGateway;
use Test2::Harness2::StateBroadcaster;
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
    <hash_seed
    state
    <run_states
    <scheduler
    <job_tracker
    <resource_services
    <pid_index
    <spawn_gateway
    <broadcaster
    <preload_router
    <collector_grace_secs
    +finish_after_initial_run
    +emitter
    watch_pids
    own_pgroup
};

# Sentinel run_id key for processes that aren't bound to a particular
# run. The canonical definition lives in Test2::Harness2::PidIndex; this
# constant is re-exported here for legacy in-tree callers.
use constant RUN_PIDS_GLOBAL_KEY => Test2::Harness2::PidIndex::RUN_PIDS_GLOBAL_KEY();

# Scheduler slot keys re-exported from Test2::Harness2::Scheduler.
# The slots themselves live on the scheduler subsystem; these
# constants exist so legacy in-tree callers (existing tests that
# poke $h->{Test2::Harness2::QUEUE()} etc.) keep resolving to a
# defined string. The harness no longer owns these slots, so the
# string names point at the scheduler object and not the harness.
use constant QUEUE                    => Test2::Harness2::Scheduler::QUEUE();
use constant SCHEDULER                => Test2::Harness2::Scheduler::SCHEDULER();
use constant IN_FLIGHT_COUNT          => Test2::Harness2::Scheduler::IN_FLIGHT_COUNT();
use constant BROKEN_RESOURCE_BEHAVIOR => Test2::Harness2::Scheduler::BROKEN_RESOURCE_BEHAVIOR();

# Re-export of the scheduler's BROKEN_BEHAVIORS lookup so legacy
# in-tree callers (and existing introspection) still resolve. The
# canonical definition lives on Test2::Harness2::Scheduler.
use constant BROKEN_BEHAVIORS => Test2::Harness2::Scheduler::BROKEN_BEHAVIORS();

# PreloadRouter slot keys re-exported. Same pattern as the
# scheduler/jobtracker shims: existing in-tree callers (tests that
# poke $h->{Test2::Harness2::PENDING_SPAWN_REQUESTS()} etc.) keep
# resolving to a defined string. The slots themselves live on the
# preload-router subsystem, not the harness.
use constant PENDING_SPAWN_REQUESTS             => Test2::Harness2::PreloadRouter::PENDING_SPAWN_REQUESTS();
use constant PENDING_PRELOAD_SPAWNS             => Test2::Harness2::PreloadRouter::PENDING_PRELOAD_SPAWNS();
use constant RESOURCES_AWAITING_PRELOAD         => Test2::Harness2::PreloadRouter::RESOURCES_AWAITING_PRELOAD();
use constant KNOWN_PRELOAD_NAMES                => Test2::Harness2::PreloadRouter::KNOWN_PRELOAD_NAMES();
use constant PRELOAD_SPAWN_TIMEOUT_SECS         => Test2::Harness2::PreloadRouter::PRELOAD_SPAWN_TIMEOUT_SECS();
use constant PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS => Test2::Harness2::PreloadRouter::PRELOAD_SERVICE_SPAWN_TIMEOUT_SECS();

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

    # _init_default_slots constructs the Scheduler subsystem, which
    # is what validates broken_resource_behavior. Pass any ctor-time
    # value through to it.
    $self->_init_default_slots;

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

    # RunStates is constructed FIRST so any subsystem that takes a
    # direct reference to it (broadcaster today; scheduler / job
    # tracker once those extractions land) can be handed the ref at
    # construction. The harness keeps a strong ref via the RUN_STATES
    # slot; RunStates does not back-reference the harness, so the
    # link stays acyclic without weakening. The run_ord_counter
    # starts at 1 here to match the pre-extraction harness behavior
    # (RunStates's own default is 0 for unit-test ergonomics; the
    # harness's seeding wins because RunStates->new defaults are
    # `//=`).
    $self->{+RUN_STATES} //= Test2::Harness2::RunStates->new(run_ord_counter => 1);

    $self->{+NAME}                      //= 'harness';
    $self->{+JOB_ID}                    //= gen_uuid();
    $self->{+KILL_TIMEOUT}              //= 15;
    $self->{+PARENT_PIDS}               //= [];
    $self->{+STATE}                     //= 'running';
    $self->{+RESOURCE_SERVICES}         //= {};
    $self->{+PID_INDEX}                 //= Test2::Harness2::PidIndex->new(harness => $self);
    $self->{+SPAWN_GATEWAY}             //= Test2::Harness2::SpawnGateway->new(harness => $self);
    $self->{+BROADCASTER}               //= Test2::Harness2::StateBroadcaster->new(
        harness    => $self,
        run_states => $self->{+RUN_STATES},
    );

    # Scheduler takes a back-ref to the harness, plus direct (strong)
    # refs to the state objects it consults on every tick. The
    # broken_resource_behavior arg arrives through Object::HashBase's
    # field-init at construction time; pluck it out of the harness
    # slot (HashBase stored it under the 'broken_resource_behavior'
    # key) and hand it to the scheduler, then delete the leftover
    # entry from the harness so the slot is owned in exactly one
    # place. Default validation lives on the scheduler.
    my $brb = delete $self->{broken_resource_behavior};
    $self->{+SCHEDULER} //= Test2::Harness2::Scheduler->new(
        harness    => $self,
        run_states => $self->{+RUN_STATES},
        pid_index  => $self->{+PID_INDEX},
        (defined $brb ? (broken_resource_behavior => $brb) : ()),
    );

    # JobTracker is constructed AFTER scheduler + broadcaster because
    # it holds direct refs to both: scheduler for run-finalization and
    # in-flight bookkeeping on job_release / synth-completion paths,
    # broadcaster for the per-state-change snapshot fanout.
    $self->{+JOB_TRACKER} //= Test2::Harness2::JobTracker->new(
        harness     => $self,
        run_states  => $self->{+RUN_STATES},
        pid_index   => $self->{+PID_INDEX},
        scheduler   => $self->{+SCHEDULER},
        broadcaster => $self->{+BROADCASTER},
    );

    $self->{+PRELOAD_ROUTER}             //= $self->_build_preload_router;
    $self->{+COLLECTOR_GRACE_SECS}       //= DEFAULT_COLLECTOR_GRACE_SECS;
    $self->{+WATCH_PIDS}                 //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}                 //= 0;

    return;
}

# Construct the preload-router subsystem. Done in its own helper so
# _init_default_slots stays under the function-length cap. The router
# is constructed last because it consults the scheduler and job-tracker
# on the launch / watchdog paths. Caller-supplied timeout overrides
# (passed as harness ctor args under the same bareword keys the old
# slots used) are forwarded so external callers that tuned them via
# Test2::Harness2->new(...) still apply.
sub _build_preload_router {
    my $self = shift;
    my %args = (
        harness     => $self,
        run_states  => $self->{+RUN_STATES},
        pid_index   => $self->{+PID_INDEX},
        scheduler   => $self->{+SCHEDULER},
        job_tracker => $self->{+JOB_TRACKER},
    );
    for my $k (qw/preload_spawn_timeout_secs preload_service_spawn_timeout_secs/) {
        $args{$k} = delete $self->{$k} if defined $self->{$k};
    }
    return Test2::Harness2::PreloadRouter->new(%args);
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

# Hand the resource a scalar ref pointing at the authoritative
# in-flight counter (owned by the scheduler subsystem). The resource
# derefs to read; no per-mutation notification loop needed.
sub _install_in_flight_ref {
    my ($self, $res) = @_;
    return unless $res && $res->can('set_in_flight_ref');
    $res->set_in_flight_ref($self->{+SCHEDULER}->in_flight_ref);
    return;
}

# Passthrough so external callers (introspection, tests, etc.) can
# still read $h->broken_resource_behavior after the slot moved to
# the scheduler subsystem.
sub broken_resource_behavior {
    my $self = shift;
    my $s = $self->{+SCHEDULER} or return undef;
    return $s->broken_resource_behavior;
}

#-------------------------------------------------------------------
# Preload routing -- thin shim. Decision logic, async spawn
# watchdogs, and dependent-resource queues all live on
# Test2::Harness2::PreloadRouter. The scheduler calls
# $h->_resolve_preload_for_job directly; this shim forwards to the
# subsystem.
#-------------------------------------------------------------------
sub _resolve_preload_for_job {
    my $self = shift;
    return $self->{+PRELOAD_ROUTER}->resolve_for_job(@_);
}

# Re-export of PreloadRouter's peer-name helpers as package functions.
# SpawnGateway used to call Test2::Harness2::_preload_peer_name(...) as
# a bare package function (extraction 3 interim wiring); the gateway
# now talks to the router via $self->harness->preload_router->...,
# but the symbol is kept here as a compatibility surface for any
# out-of-tree caller that still imports it.
sub _preload_peer_name {
    return Test2::Harness2::PreloadRouter->peer_name_for_preload(@_);
}

#-------------------------------------------------------------------
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

    my $run_id = $self->{+RUN_STATES}->next_ord;

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

        $self->{+SCHEDULER}->enqueue($run);
        $self->_install_in_flight_ref($_) for @{$run->resources // []};
        my $rstate = Test2::Harness2::Run::State->new(
            run_id     => $run->run_id,
            created_at => $run->created_at,
            pending    => [map { $_->job_id } @{$run->jobs}],
        );
        $self->{+RUN_STATES}->set_state($run->run_id, $rstate);
        $self->{+SCHEDULER}->queue_run($run);
        1;
    };
    return {ok => 0, error => "$@"} unless $ok;

    my $run = $self->{+SCHEDULER}->queue->[-1];

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

    my $run_states = $self->{+RUN_STATES};
    my $queue = [
        map {
            my $rs = $run_states->state($_->run_id);
            {
                run_id  => $_->run_id,
                pending => $rs ? [@{$rs->pending}] : [],
                running => $rs ? [@{$rs->running}] : [],
                done    => $rs ? [@{$rs->done}]    : [],
            }
        } @{$self->{+SCHEDULER}->queue}
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
    } values %{$self->{+JOB_TRACKER}->running_jobs};

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

# yath reload: thin shim that delegates to the preload router. The
# router owns the enumeration logic plus the bus-name derivation.
sub request_handler_list_preloads {
    my $self = shift;
    return $self->{+PRELOAD_ROUTER}->list;
}

# yath abort: latch user_abort onto one or all live runs. Pending
# jobs in those runs flow through the existing aborted-run synth-fail
# path (see _handle_broken_resource); currently running jobs are left
# alone (that matches the documented "remove pending tests, leave the
# runner active" semantics).
sub request_handler_abort_run {
    my ($self, $payload, $msg) = @_;

    my $states = $self->{+RUN_STATES};

    my @target_ids;
    if ($payload->{all}) {
        @target_ids = sort $states->all_run_ids;
    }
    elsif (defined $payload->{run_id}) {
        return {ok => 0, error => "no run with id '$payload->{run_id}'"}
            unless $states->state($payload->{run_id});
        @target_ids = ($payload->{run_id});
    }
    else {
        return {ok => 0, error => 'request must set either run_id or all'};
    }

    my @aborted;
    for my $rid (@target_ids) {
        my $rs = $states->state($rid) or next;
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
    my $running = scalar keys %{$self->{+JOB_TRACKER}->running_jobs // {}};
    my $queued  = scalar @{$self->{+SCHEDULER}->queue   // []};

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

    if (my $info = $self->{+RUN_STATES}->completed($run_id)) {
        return {ok => 1, %$info};
    }

    if ($self->{+SCHEDULER}->run_in_queue($run_id)) {
        return {ok => 1, state => 'running', run_id => $run_id};
    }

    return {ok => 0, error => "unknown run '$run_id'"};
}

sub run_on_general_message {
    my ($self, $msg) = @_;

    # Drain any pending retries at the top of each message tick so
    # temporary send failures resolve promptly when the bus catches up.
    if (my $bc = $self->{+BROADCASTER}) { $bc->drain_retries }

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
    return $self->{+JOB_TRACKER}->handle_job_release($content)
        if defined $kind && $kind eq 'job_release';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    return $self->{+PRELOAD_ROUTER}->handle_preload_state($kind, $content)
        if defined $kind && $kind =~ m/^preload_(?:ready|broken)$/;

    return $self->{+PRELOAD_ROUTER}->handle_service_started($content)
        if defined $kind && $kind eq 'resource_service_started';

    return $self->{+SPAWN_GATEWAY}->handle_spawned($content)
        if defined $kind && $kind eq 'script_spawned';

    # Per-job lifecycle. After Stage 4 of the RunService flatten the
    # auditor sends test_job_* events to the harness directly (the
    # collector's ipc_run was repointed). The job tracker owns
    # Run::State mutation and the run-level event emission that used
    # to live in RunService.
    return $self->{+JOB_TRACKER}->handle_test_job_started($content)
        if defined $kind && $kind eq 'test_job_started';

    return $self->{+JOB_TRACKER}->handle_test_job_diagnosing($content)
        if defined $kind && $kind eq 'test_job_diagnosing';

    return $self->{+JOB_TRACKER}->handle_test_job_failing($content)
        if defined $kind && $kind eq 'test_job_failing';

    return $self->{+JOB_TRACKER}->handle_test_job_completed($content)
        if defined $kind && $kind eq 'test_job_completed';

    # Lifecycle reflection from child collectors that route their
    # collector_start/_end up to the harness: run-service collectors
    # and global services. The harness collector itself has no parent
    # and skips emission entirely so we never receive its own pair.
    return $self->{+JOB_TRACKER}->handle_collector_start($content)
        if defined $kind && $kind eq 'collector_start';

    return $self->{+JOB_TRACKER}->handle_collector_end($content)
        if defined $kind && $kind eq 'collector_end';

    warn "Test2::Harness2: unhandled general message kind: " . (defined $kind ? "'$kind'" : '(none)') . "\n";

    return;
}

# Peer delta callback from IPC::Manager. A negative delta on a
# subscribed peer IS the signal that the peer has left the bus --
# no separate peer_exists() query is needed. Clean unsubscribes
# have already removed the peer from the broadcaster's registry, so
# anything that reaches this branch is an unexpected departure; the
# broadcaster warns and drops the registration (plus any queued
# retries).
sub run_on_peer_delta {
    my ($self, $delta) = @_;

    return unless ref($delta) eq 'HASH';

    my $bc = $self->{+BROADCASTER} or return;
    for my $peer (keys %$delta) {
        next unless $delta->{$peer} < 0;
        $bc->forget_peer($peer);
    }

    $bc->drain_retries;
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
# be told when run state changes. The harness keeps these as thin
# request-handler shims; registry, fanout, retry queueing, and
# peer-drop cleanup all live on Test2::Harness2::StateBroadcaster.

sub request_handler_subscribe {
    my $self = shift;
    return $self->{+BROADCASTER}->subscribe(@_);
}

sub request_handler_unsubscribe {
    my $self = shift;
    return $self->{+BROADCASTER}->unsubscribe(@_);
}

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS}}];
    return {ok => 1};
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
    $self->{+SCHEDULER}->clear_queue;
    return;
}

sub hard_stop_pids {
    my $self = shift;

    my %pids;

    my $running_jobs = $self->{+JOB_TRACKER}->running_jobs // {};
    for my $cur (values %$running_jobs) {
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
    my $jt = $self->{+JOB_TRACKER};
    # Best-effort resource release for every job we were tracking.
    for my $cur (values %{$jt->running_jobs // {}}) {
        $jt->release_job_resources($cur);
    }
    $jt->clear_running_jobs;
    $self->{+SCHEDULER}->reset_in_flight_count;
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+PID_INDEX}->clear;
    $self->{+RUN_STATES}->clear_flags;
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

    return if $self->{+JOB_TRACKER}->handle_collector_exit($pid, $exit);

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

# Per-tick orchestration. The harness owns the order; individual
# subsystems own the work. The collector-side synth-completion
# watchdog lives on the job tracker -- see check_synth_completions.
sub run_on_interval {
    my $self = shift;

    $self->{+PRELOAD_ROUTER}->tick;
    $self->{+SPAWN_GATEWAY}->poll;
    $self->{+JOB_TRACKER}->check_synth_completions;

    return;
}

sub run_should_end {
    my $self = shift;

    my $has_running = keys %{$self->{+JOB_TRACKER}->running_jobs // {}} ? 1 : 0;

    if ($self->{+STATE} eq 'terminating') {
        return 1 unless $has_running;
        return 0;
    }

    if ($self->{+STATE} eq 'finishing') {
        return 1 if !$has_running && !@{$self->{+SCHEDULER}->queue};
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
    my @leftover_runs = @{$self->{+SCHEDULER}->queue // []};

    my $has_running = keys %{$self->{+JOB_TRACKER}->running_jobs // {}};
    $self->perform_hard_stop if $has_running || @{$self->{+SCHEDULER}->queue};

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

# Scheduler decision logic and per-run bookkeeping live on
# Test2::Harness2::Scheduler. The harness keeps a strong reference
# under +SCHEDULER and exposes one entry point (run_on_all -> tick);
# everything else routes through $self->scheduler->method.
sub run_on_all {
    my ($self, $activity) = @_;

    # Job completion flows through the auditors: test collectors emit
    # test_job_completed which the harness routes to mirror Run mutation
    # and the broadcaster. The collector-side watchdog synthesizes
    # completion on collector death. Nothing here beyond driving the
    # scheduler forward.
    return if $self->{+STATE} eq 'terminating';

    # Launch as many pending jobs as the active resources permit this tick.
    1 while $self->{+SCHEDULER}->try_launch_next;
}

sub _ensure_run_service_started {
    my ($self, $run) = @_;

    # Method name is historical: the run service no longer exists
    # (Stage 9 of the RunService flatten). The hook still owns the
    # one-time per-run bring-up: writing the run's spec.jsonl and
    # spawning per-run resource services. The resources_started /
    # resources_torn_down flags on Run::State guard idempotency.
    my $run_states = $self->{+RUN_STATES};
    my $rstate     = $run_states->state($run->run_id);
    $rstate = $run_states->set_state(
        $run->run_id,
        Test2::Harness2::Run::State->new(run_id => $run->run_id),
    ) unless $rstate;
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
    my $report = $self->{+JOB_TRACKER}->build_collector_report($run, time);

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
    my $rstate = $self->{+RUN_STATES}->state($rid);
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
            $self->{+PRELOAD_ROUTER}->spawn_via_preload(
                $run, $job, $preload_resource,
                env                => \%env,
                assign_id          => $assign_id,
                assigned_resources => $resources,
                (defined $opts{launch} ? (launch => $opts{launch}) : ()),
                (defined $ch_dir       ? (ch_dir => $ch_dir)       : ()),
            );
            $self->{+SCHEDULER}->mark_running($run_id, $job_id);
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
    return if $self->{+SCHEDULER}->started($run_id);

    my $started_at = time;
    $self->emit_service_event(
        kind       => 'run_started',
        run_id     => $run_id,
        started_at => $started_at,
    );
    $self->{+RUN_STATES}->flags($run_id)->{started_at} //= $started_at;
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

    $self->{+SCHEDULER}->mark_running($run_id, $job_id);

    my $started_at = time;
    $self->{+JOB_TRACKER}->set_running_job($job_id, {
        run                => $run,
        job                => $job,
        pid                => $resp->{pid},
        started_at         => $started_at,
        assign_id          => $assign_id,
        assigned_resources => $resources,
        log_file           => $resp->{log_file},
    });
    $self->{+SCHEDULER}->inc_in_flight;

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
    if (my $rs = $self->{+RUN_STATES}->state($run_id)) {
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

# Handle a 'spawn_script' request from a CLI client. Thin shim that
# delegates to Test2::Harness2::SpawnGateway, which owns the SCM_RIGHTS
# pathway state and helpers.
sub request_handler_spawn_script {
    my $self = shift;
    return $self->{+SPAWN_GATEWAY}->handle_request(@_);
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

=head2 Preload routing

The preload-routing decision logic, async spawn watchdogs, and
dependent-resource queues all live on L<Test2::Harness2::PreloadRouter>.
The harness reaches the router via C<< $self->preload_router >>; call
sites elsewhere in the tree route through the router object directly
(e.g. C<< $h->preload_router->spawn_via_preload(...) >>).

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

=head2 Scheduler

The scheduler decision logic lives on L<Test2::Harness2::Scheduler>.
Callers reach the subsystem via C<< $harness->scheduler >> and invoke
its methods directly (C<queue_run>, C<mark_running>, C<mark_pending>,
etc.).

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
