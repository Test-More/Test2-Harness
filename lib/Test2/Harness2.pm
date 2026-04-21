package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/parse_exit tinysleep/;
use POSIX qw/WNOHANG/;

# When a test collector's pid is first noticed to be gone (either via a
# liveness check or a collector_exiting IPC message), the scheduler waits
# this many seconds for a real test_job_completed to arrive from the run
# service before synthesizing one. Short enough to keep the scheduler
# unblocked, long enough to cover normal IPC latency on a busy host.
use constant JOB_PID_GRACE_SECS => 5;

use Atomic::Pipe;
use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Run;
use Test2::Harness2::RunService;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <ipc_parent
    <job_id
    <loggers
    <service_loggers
    <test_auditor
    <test_loggers
    <kill_timeout
    <parent_pids
    <jump_to
    <resources
    <plugins
    <broken_resource_behavior
    <launch_args
    +state
    +queue
    +running_jobs
    <resource_services
    +run_services
    +finish_after_initial_run
    +emitter
    +watch_pids_ref
    +own_pgroup
    +completed_runs
    +global_artifacts
    +run_artifacts
};

# Valid values for broken_resource_behavior: what the scheduler does
# when a job needs a resource that has been flipped to
# permanent_broken. All three paths route the job through a real
# Collector launch so the on-disk artifacts match a real test's --
# see _launch_synthetic_job.
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

use Role::Tiny::With;
with 'Test2::Harness2::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

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

    $self->{+NAME}              //= 'harness';
    $self->{+JOB_ID}            //= gen_uuid();
    $self->{+KILL_TIMEOUT}      //= 15;
    $self->{+PARENT_PIDS}       //= [];
    $self->{+STATE}             //= 'running';
    $self->{+QUEUE}             //= [];
    $self->{+RUNNING_JOBS}      //= {};
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+RUN_SERVICES}      //= {};
    $self->{+COMPLETED_RUNS}    //= {};
    $self->{+GLOBAL_ARTIFACTS}  //= {};
    $self->{+RUN_ARTIFACTS}     //= {};
    $self->{+WATCH_PIDS_REF}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    $self->{+BROKEN_RESOURCE_BEHAVIOR} //= 'skip';
    croak "invalid broken_resource_behavior '$self->{+BROKEN_RESOURCE_BEHAVIOR}' (want skip, fail, or abort)"
        unless BROKEN_BEHAVIORS->{$self->{+BROKEN_RESOURCE_BEHAVIOR}};

    # Plugins are stored as-is so the harness service, the scheduler,
    # and the run service can all reach them. Per-hook dispatch into
    # Scheduler / RunService / Collector lands as each of those
    # consumers grows a real use for the hook (stages 8+); this
    # stage's contract is just "the harness accepts them and does
    # not lose them".
    my $plugins = $self->{+PLUGINS} // [];
    croak "'plugins' must be an arrayref" unless ref($plugins) eq 'ARRAY';
    $self->{+PLUGINS} = $plugins;

    $self->_init_resources;

    # Loggers default to empty: the caller decides what (if anything)
    # gets written to disk. Three independent lists control the three
    # service tiers the harness manages:
    #
    #   loggers          Run on the harness's OWN Collector interpose.
    #                    A typical harness config might put a JSONL +
    #                    JSON pair here pointing at
    #                    "$logdir/services/$NAME.{jsonl,json}".
    #
    #   service_loggers  Applied to each child service the harness
    #                    starts (RunService and resource services).
    #                    Runs may extend or replace this list per-run
    #                    via queue_test_run.
    #
    #   test_loggers     Applied to the per-test-job Collector spawned
    #                    inside a RunService. Runs may extend or
    #                    replace this list per-run via queue_test_run.
    #
    # Each slot is an arrayref of logger specs: either a blessed
    # logger instance or an arrayref [$class, %args] that the
    # Collector instantiates in the child process.
    $self->{+LOGGERS}         //= [];
    $self->{+SERVICE_LOGGERS} //= [];
    $self->{+TEST_LOGGERS}    //= [];

    croak "'loggers' must be an arrayref"
        unless ref($self->{+LOGGERS}) eq 'ARRAY';
    croak "'service_loggers' must be an arrayref"
        unless ref($self->{+SERVICE_LOGGERS}) eq 'ARRAY';
    croak "'test_loggers' must be an arrayref"
        unless ref($self->{+TEST_LOGGERS}) eq 'ARRAY';

    # The test auditor default is still set here: it's a class-level
    # concern, not a per-instance logger, and a run-complete
    # pass/fail verdict is useless without it.
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
}

sub _init_resources {
    my $self = shift;

    $self->{+RESOURCES} //= [];

    # At least one job-count limiter must be active. Fall back to a
    # single-slot JobCount if the caller did not supply one; this preserves
    # the legacy "one at a time" behaviour when the harness is used without
    # explicit concurrency configuration.
    my $has_limiter = grep { $_->is_job_limiter } @{$self->{+RESOURCES}};
    push @{$self->{+RESOURCES}} => Test2::Harness2::Resource::JobCount->new(slots => 1)
        unless $has_limiter;
}

# Env vars the harness service must NOT inherit when it starts up.
# These are collector- / formatter- / per-job plumbing set by an outer
# yath when it was launching *us* as a test, and keeping them in place
# inside a yath-under-yath inner service causes the inner process to
# act as if it were still a test child of the outer harness (emitting
# Stream2 frames into the outer's pipe, fabricating per-job metadata
# from the outer run, treating TEST2_ACTIVE as already set, etc.).
#
# This list is intentionally narrower than old/lib/App/Yath2.pm's
# clear_env:
#   - HARNESS_IS_VERBOSE / T2_HARNESS_IS_VERBOSE are *user*-settable
#     (Options::Renderer's verbose option wires them via set_env_vars).
#     The old path cleared them *before* parsing options; we cannot do
#     that here because options have already been parsed by the time
#     the harness service starts. Leaving them in place respects the
#     caller's --verbose setting.
#   - T2_HARNESS_PRELOAD is likewise option-settable.
# When App::Yath2 grows a real top-level entry point that clears env
# before option parsing (Stage 4 successor), the pre-options set can
# move there; Harness2 would keep the narrow post-options set below.
sub _clear_problematic_env {
    delete $ENV{T2_FORMATTER};
    delete $ENV{T2_HARNESS2_PIPE_COUNT};
    delete $ENV{T2_HARNESS_FORKED};
    delete $ENV{T2_HARNESS_JOB_IS_TRY};
    delete $ENV{T2_HARNESS_JOB_NAME};
    delete $ENV{T2_STREAM_DIR};
    delete $ENV{T2_STREAM_FILE};
    delete $ENV{T2_STREAM_JOB_ID};
    delete $ENV{TEST2_JOB_DIR};
    delete $ENV{TEST2_RUN_DIR};

    # TEST2_ACTIVE / TEST_ACTIVE / TEST2_HARNESS_ACTIVE advertise "Test2::API
    # is already running a test". If Test2::API really is loaded in this
    # process we leave them alone -- it reads them at BEGIN time and a later
    # delete would confuse the runtime. Otherwise they are stale signals
    # from the outer yath and safe to clear.
    unless ($INC{'Test2/API.pm'}) {
        delete $ENV{TEST2_ACTIVE};
        delete $ENV{TEST_ACTIVE};
        delete $ENV{TEST2_HARNESS_ACTIVE};
    }

    return;
}

sub start {
    my ($class, %args) = @_;

    _clear_problematic_env();

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
        $ipcm_guard = ipcm_spawn();
        $args{ipcm_info} = $ipcm_guard->info;
    }

    # Construct the service object in the pre-fork process.  init() creates
    # $workdir/logs/services/ and populates default loggers.
    my $self = $class->new(%args);

    # Grab the loggers to hand to interpose before forking.
    my $loggers = $self->{+LOGGERS};

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
    # is the top of its own tree. ipc_parent stays undef; ipc_harness
    # points at the service-side name so the collector can still
    # deliver its end-of-life report to the harness if ever consumed
    # by an external orchestrator on the same bus.
    Test2::Harness2::Collector->interpose(
        ipcm_info   => $self->ipcm_info,
        ipc_parent  => undef,
        ipc_run     => undef,
        ipc_harness => $self->{+NAME},
        kind        => 'service',
        loggers     => $loggers,
        parser      => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids => [$caller_pid],
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

    $args{parent_pids} //= [$$];

    # Spawn the IPC bus in the parent so both parent and child share the same
    # connection info.  Use guard => 0 so the parent does not try to tear down
    # the bus when the Spawn object goes out of scope; the child owns it.
    my $ipcm = ipcm_spawn(guard => 0);
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

    # loggers / extend_loggers and test_loggers / extend_test_loggers
    # carry the caller's per-run intent. The Run constructor
    # validates mutual exclusivity and shape; surface a tidy error
    # response rather than letting the croak escape.
    my %run_logger_opts;
    for my $k (qw/loggers extend_loggers test_loggers extend_test_loggers/) {
        $run_logger_opts{$k} = $payload->{$k} if defined $payload->{$k};
    }

    my $ok = eval {
        my $run = Test2::Harness2::Run->from_files(
            files => $files,
            (defined $payload->{run_id} ? (run_id => $payload->{run_id}) : ()),
            %run_logger_opts,
        );
        push @{$self->{+QUEUE}} => $run;
        1;
    };
    my $err = $@;
    return {ok => 0, error => "$err"} unless $ok;

    my $run = $self->{+QUEUE}->[-1];

    # Dispatch the run_queued hook against every plugin attached to
    # the harness. A plugin may return a list of "run fields" (a
    # field being a hashref with name / details / raw / data keys, as
    # per the old harness_run_fields facet), which we stamp onto the
    # run before the run_queued service event fires. That way the
    # event's run_data snapshot includes the plugin-supplied metadata.
    #
    # Each plugin is run inside its own eval so that a broken plugin
    # cannot poison the queue operation; the error is warned and the
    # next plugin is tried.
    for my $plugin (@{$self->{+PLUGINS}}) {
        next unless $plugin->can('run_queued');
        my @fields;
        my $pok = eval { @fields = $plugin->run_queued($run); 1 };
        my $perr = $@;
        unless ($pok) {
            warn "Plugin '", (ref($plugin) || $plugin), "' run_queued hook failed: $perr";
            next;
        }
        $run->add_fields(@fields) if @fields;
    }

    $self->emit_service_event(
        kind     => 'run_queued',
        run_data => $run->TO_JSON,
    );

    for my $job (@{$run->jobs}) {
        $self->emit_service_event(
            kind     => 'job_queued',
            job_data => $job->TO_JSON,
        );
    }

    return {ok => 1, run_id => $run->run_id};
}

sub request_handler_status {
    my $self = shift;

    my $queue = [
        map { {
            run_id     => $_->run_id,
            pending    => [@{$_->pending}],
            running    => [@{$_->running}],
            done       => [@{$_->done}],
            pass_count => $_->pass_count,
            fail_count => $_->fail_count,
        } } @{$self->{+QUEUE}}
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
    };
}

# Per-run state query. Returns:
#   { ok => 1, state => 'running'|'completed', run_id, pending, running,
#     done, pass_count, fail_count }
# for a run the harness has seen, either still in the queue or moved
# into the completed_runs snapshot after it finished. Returns
#   { ok => 0, error => '...' } for an unknown run_id.
#
# The completed snapshot is what makes this query safe to call after
# the run has drained: the queue prunes finished runs, but their
# terminal state is captured into completed_runs first.
sub request_handler_run_status {
    my ($self, $payload) = @_;
    $payload //= {};

    my $run_id = $payload->{run_id};
    return {ok => 0, error => "'run_id' is required"}
        unless defined $run_id && length $run_id;

    for my $run (@{$self->{+QUEUE}}) {
        next unless $run->run_id eq $run_id;
        return {
            ok         => 1,
            state      => 'running',
            run_id     => $run_id,
            pending    => [@{$run->pending}],
            running    => [@{$run->running}],
            done       => [@{$run->done}],
            pass_count => $run->pass_count,
            fail_count => $run->fail_count,
            jobs       => _run_job_info($run),
        };
    }

    if (my $snap = $self->{+COMPLETED_RUNS}->{$run_id}) {
        return {ok => 1, state => 'completed', %$snap};
    }

    return {ok => 0, error => "unknown run_id '$run_id'"};
}

# Per-job metadata map: job_id => { test_file => ..., test_file_abs => ... }
# Added to run_status so the command-side artifact-reading layer can
# surface filename-shaped renderer events (IPC_AND_LOGGERS §13.0: the
# renderer receives events, not raw harness state; adding job metadata
# here keeps the one-query-per-poll pattern the ArtifactReader uses).
sub _run_job_info {
    my ($run) = @_;
    my %out;
    for my $job (@{$run->jobs // []}) {
        my $jid = eval { $job->job_id }  // next;
        my $rel = eval { $job->test_file_rel };
        my $abs = eval { $job->test_file_abs };
        $out{$jid} = {
            (defined $rel ? (test_file     => $rel) : ()),
            (defined $abs ? (test_file_abs => $abs) : ()),
        };
    }
    return \%out;
}

# get_workdir: per IPC_AND_LOGGERS §11.2 an attached command asks the
# harness where its workdir is. Returns the absolute path of the
# harness's workdir plus the configured logdir (which may already be
# absolute if the caller supplied one).
sub request_handler_get_workdir {
    my $self = shift;
    return {
        ok      => 1,
        workdir => $self->{+WORKDIR},
        logdir  => $self->{+LOGDIR},
        name    => $self->{+NAME},
    };
}

# list_processes: enumerate the harness's tracked process tree. Used by
# `yath ps`. Returns one entry per service / collector / test-job
# process the harness knows about. The harness is the source of truth
# here -- run services, resource services, and test-job pids are all
# tracked in-memory already; we just lift them into the response.
sub request_handler_list_processes {
    my $self = shift;

    my @procs;

    push @procs => {
        pid  => $$,
        type => 'service',
        role => 'harness',
        name => $self->{+NAME},
    };

    for my $rid (keys %{$self->{+RUN_SERVICES} // {}}) {
        my $info = $self->{+RUN_SERVICES}->{$rid};
        next unless $info->{pid};
        push @procs => {
            pid    => $info->{pid},
            type   => 'service',
            role   => 'run',
            run_id => $rid,
            name   => $info->{bus_name},
            ($info->{started_at} ? (started_at => $info->{started_at}) : ()),
        };
    }

    for my $key (keys %{$self->{+RESOURCE_SERVICES} // {}}) {
        my $info = $self->{+RESOURCE_SERVICES}->{$key};
        next unless $info->{pid};
        push @procs => {
            pid  => $info->{pid},
            type => 'service',
            role => 'resource',
            name => $info->{service_name} // $key,
            ($info->{resource_name} ? (resource_name => $info->{resource_name}) : ()),
        };
    }

    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid};
        push @procs => {
            pid        => $cur->{pid},
            type       => 'collector',
            role       => 'test',
            run_id     => $cur->{run}->run_id,
            job_id     => $job_id,
            test_file  => $cur->{job}->test_file_rel,
            ($cur->{started_at} ? (started_at => $cur->{started_at}) : ()),
        };
    }

    return {ok => 1, processes => \@procs};
}

# list_resources: report the current state of every resource attached
# to the harness, global or per-run. Used by `yath resources`. Each
# resource's `status` method is the authoritative source; we extend
# each status hash with `scope`, `resource_name`, `class`, and (for
# run-scoped resources) the owning run_id.
sub request_handler_list_resources {
    my $self = shift;

    my @entries;

    for my $res (@{$self->{+RESOURCES} // []}) {
        my $status = eval { $res->status } // {};
        push @entries => {
            class         => ref($res),
            resource_name => $res->resource_name,
            scope         => 'global',
            is_paused           => $res->is_paused           ? 1 : 0,
            is_broken           => $res->is_broken           ? 1 : 0,
            is_permanent_broken => $res->is_permanent_broken ? 1 : 0,
            is_usable           => $res->is_usable           ? 1 : 0,
            status              => $status,
        };
    }

    for my $rid (keys %{$self->{+RUN_SERVICES} // {}}) {
        my $run = $self->{+RUN_SERVICES}->{$rid}->{run} // next;
        for my $res (@{$run->resources // []}) {
            my $status = eval { $res->status } // {};
            push @entries => {
                class         => ref($res),
                resource_name => $res->resource_name,
                scope         => 'run',
                run_id        => $rid,
                is_paused           => $res->is_paused           ? 1 : 0,
                is_broken           => $res->is_broken           ? 1 : 0,
                is_permanent_broken => $res->is_permanent_broken ? 1 : 0,
                is_usable           => $res->is_usable           ? 1 : 0,
                status              => $status,
            };
        }
    }

    return {ok => 1, resources => \@entries};
}

# abort_runs: drop every run in the queue and mark currently-running
# jobs aborted so the scheduler stops launching new tests without
# tearing the harness down. Currently-running jobs continue to
# completion (per the "abort" semantic in the old yath: stop queuing,
# let in-flight finish). The harness stays up and can accept new
# runs -- callers who want the harness to exit after aborting should
# follow up with a `finish` request.
sub request_handler_abort_runs {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'service not running'}
        unless $self->{+STATE} eq 'running';

    my @aborted;
    for my $run (@{$self->{+QUEUE} // []}) {
        my $rid = $run->run_id;
        next if defined $payload->{run_id} && $run->run_id ne $payload->{run_id};

        # mark_skipped every pending job so the run finalises without
        # launching any more work; running jobs are left alone so
        # in-flight tests complete normally.
        for my $job_id (@{$run->pending}) {
            $run->mark_skipped($job_id);
        }
        push @aborted => $rid;
    }

    # _try_launch_next_pending runs every tick; finalise runs that
    # have no pending / no running so their completion propagates
    # now rather than waiting for the next scheduling pass.
    for my $run (@{$self->{+QUEUE} // []}) {
        $self->_finalize_run_if_complete($run);
    }

    return {ok => 1, aborted => \@aborted};
}

# reload_preloads: forward the reload request to every Preload resource
# the harness has. The resource's own `request_reload` hook decides
# what to do; Stage 9 lays the scaffolding (ChangeWatcher + Reloader
# roles) and the preload service will grow a concrete reload path
# later. For Stage 14 the contract is: accept the request, return
# which preload resources were notified, and let the resource layer
# do whatever it currently does.
sub request_handler_reload_preloads {
    my $self = shift;

    my @reloaded;
    for my $res (@{$self->{+RESOURCES} // []}) {
        next unless ref($res) && $res->isa('Test2::Harness2::Resource::Preload');
        my $ok = eval {
            $res->request_reload if $res->can('request_reload');
            1;
        };
        warn "preload '" . $res->resource_name . "' reload failed: $@" unless $ok;
        push @reloaded => $res->resource_name;
    }

    return {ok => 1, reloaded => \@reloaded};
}

# Store a collector_artifacts payload into the appropriate bucket.
# See IPC_AND_LOGGERS §8. The inner shape is
# { collector_id => { loggers => { Class => [\%inst, ...] }, run_id?, job_id?, job_try? } }
# which is what list_global_artifacts / list_run_artifacts return.
sub _record_artifacts {
    my ($self, $payload) = @_;
    return unless ref($payload) eq 'HASH';

    my $loggers      = $payload->{loggers} // {};
    my $run_id       = $payload->{run_id};
    my $job_id       = $payload->{job_id};
    my $job_try      = $payload->{job_try};
    my $collector_id = $payload->{collector_id} // $job_id;
    return unless defined $collector_id;

    my $bucket;
    if (defined $run_id && length $run_id) {
        $self->{+RUN_ARTIFACTS}->{$run_id} //= {};
        $bucket = $self->{+RUN_ARTIFACTS}->{$run_id};
    }
    else {
        $bucket = $self->{+GLOBAL_ARTIFACTS};
    }

    my $entry = $bucket->{$collector_id} //= {
        collector_id => $collector_id,
        loggers      => {},
        (defined $run_id  ? (run_id  => $run_id)  : ()),
        (defined $job_id  ? (job_id  => $job_id)  : ()),
        (defined $job_try ? (job_try => $job_try) : ()),
    };

    for my $class (keys %$loggers) {
        my $instances = $loggers->{$class};
        $instances = [$instances] unless ref($instances) eq 'ARRAY';
        push @{$entry->{loggers}->{$class}} => @$instances;
    }

    return;
}

# Batch ingest artifacts a run service forwards to us at run end (or
# sooner). Each payload entry is a collector_id => { loggers, ... }
# snapshot collected by the run service. Used by the
# run_artifacts_snapshot IPC message.
sub _ingest_run_artifacts {
    my ($self, $run_id, $snapshot) = @_;
    return unless defined $run_id && length $run_id;
    return unless ref($snapshot) eq 'HASH';

    for my $collector_id (keys %$snapshot) {
        my $entry   = $snapshot->{$collector_id};
        my $loggers = ref($entry) eq 'HASH' ? ($entry->{loggers} // {}) : {};
        $self->_record_artifacts({
            collector_id => $collector_id,
            run_id       => $run_id,
            job_id       => ref($entry) eq 'HASH' ? $entry->{job_id}  : undef,
            job_try      => ref($entry) eq 'HASH' ? $entry->{job_try} : undef,
            loggers      => $loggers,
        });
    }
    return;
}

# Artifact enumeration requests for the command-side artifact-reading
# layer. See IPC_AND_LOGGERS §13.1.
#
# list_global_artifacts: artifacts from every non-run-scoped collector
# the harness has learned about (harness's own interpose, global
# resource services, global preload stages).
sub request_handler_list_global_artifacts {
    my $self = shift;
    return {
        ok        => 1,
        artifacts => _clone_artifacts($self->{+GLOBAL_ARTIFACTS} // {}),
    };
}

# list_run_artifacts: artifacts from every collector scoped to a
# specific run_id (the run service's own interpose, run-scoped
# resource services, run-scoped preload stages, test-job collectors
# launched inside that run -- including tests launched from a
# detached preload stage).
sub request_handler_list_run_artifacts {
    my ($self, $payload) = @_;
    $payload //= {};

    my $run_id = $payload->{run_id};
    return {ok => 0, error => "'run_id' is required"}
        unless defined $run_id && length $run_id;

    my $bucket = $self->{+RUN_ARTIFACTS}->{$run_id} // {};
    return {ok => 1, run_id => $run_id, artifacts => _clone_artifacts($bucket)};
}

# get_run_status: alias for request_handler_run_status so the
# artifact-reading layer can use the name the spec prefers. Re-exports
# the per-run aggregate (pass_count, fail_count, done, ...).
sub request_handler_get_run_status {
    my ($self, $payload) = @_;
    return $self->request_handler_run_status($payload);
}

sub _clone_artifacts {
    my ($bucket) = @_;
    my %out;
    for my $cid (keys %$bucket) {
        my $entry   = $bucket->{$cid};
        my $loggers = $entry->{loggers} // {};

        my %loggers_copy;
        for my $class (keys %$loggers) {
            # Shallow-copy each instance hash so the caller cannot
            # mutate our stored state by editing the response.
            $loggers_copy{$class} = [map { {%$_} } @{$loggers->{$class} // []}];
        }

        $out{$cid} = {
            collector_id => $entry->{collector_id},
            loggers      => \%loggers_copy,
            (defined $entry->{run_id}  ? (run_id  => $entry->{run_id})  : ()),
            (defined $entry->{job_id}  ? (job_id  => $entry->{job_id})  : ()),
            (defined $entry->{job_try} ? (job_try => $entry->{job_try}) : ()),
        };
    }
    return \%out;
}

sub request_handler_finish {
    my $self = shift;
    return {ok => 0} unless $self->{+STATE} eq 'running';
    $self->{+STATE} = 'finishing';
    return {ok => 1};
}

sub run_on_general_message {
    my ($self, $msg) = @_;

    my $content = $msg->content;
    my $kind    = ref($content) eq 'HASH' ? $content->{kind} : undef;

    # The act of receiving this message has already woken the service's event
    # loop. On the next run_on_all iteration the scheduler re-ticks. Nothing
    # else to do.
    return if defined $kind && $kind eq 'job_complete_notify';

    # A per-run RunService reports a test job's final exit status here so
    # the harness can release resources and advance its scheduler.
    return $self->_handle_job_complete($content)
        if defined $kind && $kind eq 'test_job_completed';

    # A collector reports its own end-of-life with kind/role info and,
    # for test collectors, the auditor's pass/fail verdict + child
    # exit code. The harness uses this to arm a pid-gone grace timer
    # (so the scheduler advances even when the RunService's reap
    # message is delayed or lost) and to override the coarse exit-
    # code-based pass inference with the auditor's real verdict.
    return $self->_handle_collector_exiting($content)
        if defined $kind && $kind eq 'collector_exiting';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    if (defined $kind && $kind eq 'collector_artifacts') {
        # A collector has reported the artifacts its loggers produce.
        # See IPC_AND_LOGGERS §8: announcements route directly to
        # ipc_run if the collector has one, else ipc_harness. The
        # run service stashes its own arrivals; the harness stashes
        # everything it receives directly.
        #
        # Two buckets:
        #   GLOBAL_ARTIFACTS  - keyed by collector_id (harness's own
        #                       collector, global resource-service
        #                       collectors, global preload stages).
        #                       Returned by list_global_artifacts.
        #   RUN_ARTIFACTS     - keyed by run_id, then collector_id.
        #                       Forwarded from each run service at
        #                       run end (or per-message for quicker
        #                       visibility while the run is live).
        #
        # Stage 12 takes the conservative path: if the payload
        # carries a run_id, file it under that run_id; otherwise
        # it's a global announcement. Successive announcements are
        # additive (merge classes, append instances) per §8.2.
        $self->_record_artifacts($content);
        $self->emit_service_event(
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

    warn "Test2::Harness2: unhandled general message kind: " . (defined $kind ? "'$kind'" : '(none)') . "\n";

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

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS_REF} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS_REF}}];
    return {ok => 1};
}

# A collector has reached end-of-life and is sending its final
# summary. Two things to do:
#
#   1. Arm the pid-gone grace timer so the scheduler can advance
#      even if the RunService's own SIGCHLD reap message is delayed
#      or dropped -- test_job_completed from the RunService still wins if
#      it arrives first, otherwise we synthesize one on grace expiry.
#
#   2. For test-kind collectors, record the auditor's pass verdict
#      in the running_jobs entry. _handle_job_complete, when it
#      runs, prefers this verdict over the coarse exit-code-based
#      pass inference -- the auditor knows about failed assertions
#      that did not change the exit code, which exit-code alone can
#      miss.
#
# Non-test collectors (role => 'service', resource service
# collectors, ...) are informational only; the payload's exit code
# is enough for anything else that wants it.
sub _handle_collector_exiting {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $job_id = $content->{job_id};
    return unless defined $job_id;

    my $cur = $self->{+RUNNING_JOBS}->{$job_id} or return;
    $cur->{pid_gone_since} //= time;

    my $role = $content->{role} // 'generic';
    if ($role eq 'test' && exists $content->{pass}) {
        $cur->{auditor_pass} = $content->{pass} ? 1 : 0;
    }

    return;
}

sub _handle_job_complete {
    my ($self, $content) = @_;

    my $job_id = ref($content) eq 'HASH' ? $content->{job_id} : undef;
    return unless defined $job_id;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;

    # The run service reports exit in the IPC payload (a raw wait status).
    # Parse it once, then emit a job_completed lifecycle event for any
    # listeners following the harness's own log.
    my $raw_exit = ref($content) eq 'HASH' ? $content->{exit}      : undef;
    my $exit     = defined($raw_exit)      ? parse_exit($raw_exit) : undef;

    # Prefer the auditor's verdict (recorded via collector_exiting)
    # when it was reported; fall back to the coarse exit-code check.
    # A test can have failed assertions while still exiting 0, which
    # exit-code alone cannot see.
    my $pass;
    if (exists $cur->{auditor_pass}) {
        $pass = $cur->{auditor_pass} ? 1 : 0;
    }
    else {
        $pass = defined($exit) && $exit->{err} == 0 && $exit->{sig} == 0 ? 1 : 0;
    }

    $self->emit_service_event(
        kind     => 'job_completed',
        job_info => {
            run_id  => $cur->{run}->run_id,
            job_id  => $cur->{job}->job_id,
            job_try => $cur->{job}->job_try,
        },
        exit => $exit,
        pass => $pass,
    );

    # Release any resources this job had assigned and advance the run.
    $self->_release_job_resources($cur);
    $cur->{run}->mark_done($job_id, $pass);

    if ($cur->{run}->is_complete) {
        my $run    = $cur->{run};
        my $run_id = $run->run_id;

        # Capture the run's terminal state before it's pruned from
        # the queue. Callers (yath test, yath run) query their
        # specific run_id via request_handler_run_status; that
        # handler falls through to this snapshot after the run is
        # gone from the queue.
        $self->{+COMPLETED_RUNS}->{$run_id} = {
            run_id     => $run_id,
            pending    => [@{$run->pending}],
            running    => [@{$run->running}],
            done       => [@{$run->done}],
            pass_count => $run->pass_count,
            fail_count => $run->fail_count,
            jobs       => _run_job_info($run),
        };

        $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];

        $self->_teardown_run_service($run);

        $self->emit_service_event(
            kind     => 'run_ended',
            run_data => {run_id => $run_id},
        );

        $self->{+STATE} = 'finishing'
            if $self->{+FINISH_AFTER_INITIAL_RUN}
            && $self->{+STATE} eq 'running';
    }

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

    # Run services cascade their own TERM handlers down to per-run
    # resource services and test collectors, so signalling the run
    # service is enough to take its whole subtree down.
    for my $info (values %{$self->{+RUN_SERVICES} // {}}) {
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
    $self->{+RESOURCE_SERVICES} = {};
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

    # Run-service exit. The per-run supervisor finished on its own
    # (either because _teardown_run_service sent it TERM, or because
    # its parent-pid watch tripped and it exited voluntarily). Drop
    # its tracking entry and move on; any resource-service state
    # reported via IPC has already been applied.
    for my $rid (keys %{$self->{+RUN_SERVICES} // {}}) {
        my $info = $self->{+RUN_SERVICES}->{$rid};
        next unless $info->{pid} && $info->{pid} == $pid;
        delete $self->{+RUN_SERVICES}->{$rid};
        return;
    }

    # Orphan test-collector exit: a test whose run service died mid-run
    # may reparent to us (via subreaper or by init). Normally the run
    # service would have sent test_job_completed first; only reach this branch
    # if that didn't happen. Release resources and mark the job done so
    # the scheduler doesn't wait forever.
    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        warn "Test2::Harness2: orphaned test pid $pid exited with $exit (job $job_id); " . "its run service died before reporting\n";
        $self->_handle_job_complete({
            kind   => 'test_job_completed',
            run_id => $cur->{run}->run_id,
            job_id => $job_id,
            pid    => $pid,
            exit   => $exit,
        });
        return;
    }

    # Resource-service exit (handled by the shared host role, which
    # takes care of restart-spiral protection, state flags, and
    # re-invocation). Reparented descendants that aren't one of ours
    # silently fall through.
    $self->handle_resource_service_exit($pid, $exit);

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

sub run_on_all {
    my ($self, $activity) = @_;

    # Job completion is driven by the test_job_completed IPC message the run
    # services send when a test collector exits (see _handle_job_complete),
    # backstopped by the pid-liveness watchdog in run_on_interval. Here
    # we only drive the scheduler forward.
    return if $self->{+STATE} eq 'terminating';

    # Launch as many pending jobs as the active resources permit this tick.
    1 while $self->_try_launch_next_pending;
}

# IPC::Manager calls run_on_interval every $self->interval seconds
# (0.2s by default), which is where we park our per-job pid-liveness
# watchdog. The check protects the scheduler from hanging forever when
# a test_job_completed fails to land (crashed run service, test spawned
# outside the run's tree, IPC bus hiccup, ...).
sub run_on_interval {
    my $self = shift;
    $self->_check_running_job_pids;
    return;
}

# Walk each running_jobs entry and make sure the collector's pid is
# still alive. The state machine has three rungs:
#
#   * No pid_gone_since: do one kill(0, $pid) check. If the pid is
#     gone, stamp pid_gone_since and move on. PID numbers get recycled,
#     so we never perform another liveness check after this stamp is
#     set -- a later "live" reading from kill(0) would be against a
#     process that just happens to have taken the slot.
#
#   * pid_gone_since set, within the grace window: do nothing and wait
#     for the real test_job_completed to arrive.
#
#   * pid_gone_since set, grace window elapsed: synthesize a
#     test_job_completed so the scheduler can release resources and advance.
#     We log a warning because a missing test_job_completed is an unusual
#     path (collector crashed or reparented outside the run service's
#     reach), worth flagging in the harness log.
sub _check_running_job_pids {
    my $self = shift;

    my $now     = time;
    my $running = $self->{+RUNNING_JOBS} // {};

    for my $job_id (keys %$running) {
        my $cur = $running->{$job_id};
        my $pid = $cur->{pid};
        next unless defined $pid;

        unless (defined $cur->{pid_gone_since}) {
            next if kill 0, $pid;
            $cur->{pid_gone_since} = $now;
            next;
        }

        next if ($now - $cur->{pid_gone_since}) < JOB_PID_GRACE_SECS;

        warn sprintf(
            "Test2::Harness2: synthesizing test_job_completed for job %s (pid %d): " . "pid gone for %ds without a test_job_completed report\n",
            $job_id, $pid, JOB_PID_GRACE_SECS,
        );

        $self->_handle_job_complete({
            kind        => 'test_job_completed',
            run_id      => $cur->{run}->run_id,
            job_id      => $job_id,
            pid         => $pid,
            exit        => undef,                  # raw wait status unknown
            synthesized => 1,
        });
    }

    return;
}

sub _try_launch_next_pending {
    my $self = shift;

    return 0 unless @{$self->{+QUEUE} // []};

    for my $run (@{$self->{+QUEUE}}) {
        next if $run->is_complete;

        # Lazy per-run resource startup: the first time this run is
        # considered for launch we spin up its resource services.
        $self->_ensure_run_service_started($run);

        for my $job_id (@{$run->pending}) {
            my ($job) = grep { $_->job_id eq $job_id } @{$run->jobs};
            next unless $job;

            # Run-level abort state (see _handle_broken_resource):
            # once a run is aborted, every remaining job takes the
            # synthetic-fail path, whether or not that specific job
            # needed the broken resource. The aborted flag on the
            # decision distinguishes the original trigger (aborted=0)
            # from follow-ups swept up by the abort (aborted=1).
            my ($decision, $arg, %dec_opts);
            if (defined $run->{aborted_reason}) {
                ($decision, $arg) = ('broken', $run->{aborted_reason});
                $dec_opts{aborted} = 1;
            }
            else {
                ($decision, $arg) = $self->_evaluate_resources_for($run, $job);
            }

            if ($decision eq 'skip') {
                # The resource set can never satisfy this job. Drop
                # it from pending; no synthesized completion event
                # (this is not a failure, the job just could not
                # run).
                $run->mark_skipped($job_id);
                $self->_finalize_run_if_complete($run);
                return 1;
            }

            if ($decision eq 'broken') {
                # A needed resource has been permanently broken (or
                # the run has been aborted wholesale).
                # broken_resource_behavior decides how the job is
                # dispatched; the synth launch shares the job-limiter
                # pool and may defer if the pool is saturated.
                my $outcome = $self->_handle_broken_resource($run, $job, $arg, %dec_opts);
                return 1 if $outcome eq 'launched' || $outcome eq 'skip';
                next;    # 'defer' -- try the next job/run
            }

            next if $decision eq 'defer';

            $self->_launch_job($run, $job, $arg);
            return 1;
        }
    }

    return 0;
}

# Finalize the run if it's complete: drop it from the queue, tear
# down its per-run service, and transition the harness to finishing
# if we're in finish_after_initial_run mode.
sub _finalize_run_if_complete {
    my ($self, $run) = @_;
    return unless $run->is_complete;

    my $run_id = $run->run_id;

    # Same snapshot contract as _handle_job_complete: capture the
    # run's terminal state into completed_runs before the queue
    # pruning erases it, so request_handler_run_status can still
    # answer for this run_id afterwards.
    $self->{+COMPLETED_RUNS}->{$run_id} //= {
        run_id     => $run_id,
        pending    => [@{$run->pending}],
        running    => [@{$run->running}],
        done       => [@{$run->done}],
        pass_count => $run->pass_count,
        fail_count => $run->fail_count,
        jobs       => _run_job_info($run),
    };

    $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];
    $self->_teardown_run_service($run);
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
# That way the loggers, auditor, and on-disk artifacts are produced
# the same way they would be for a real test; no job is ever silently
# dropped.
#
# Returns 'launched', 'defer' (limiter full), or 'skip' (the synth
# launch is impossible: e.g. no job-limiter is usable any more).
sub _handle_broken_resource {
    my ($self, $run, $job, $resource_name, %opts) = @_;

    my $behavior = $self->{+BROKEN_RESOURCE_BEHAVIOR};
    my $aborted  = $opts{aborted} ? 1 : 0;

    if ($behavior eq 'skip') {
        return $self->_launch_synthetic_job(
            $run, $job, 'skip', $resource_name, aborted => $aborted,
        );
    }

    if ($behavior eq 'fail') {
        return $self->_launch_synthetic_job(
            $run, $job, 'fail', $resource_name, aborted => $aborted,
        );
    }

    # abort: record the reason on the run so every other pending job
    # also takes the fail path (see _try_launch_next_pending), then
    # synthesize fail for THIS job. The scheduler drives the rest one
    # at a time as the job limiter frees slots -- we never try to
    # launch N synth-fail jobs against a single-slot limiter at once.
    # The current job is the trigger; follow-ups arrive through the
    # scheduler's aborted-run branch with aborted => 1 already set
    # on their dec_opts.
    $run->{aborted_reason} //= $resource_name;
    return $self->_launch_synthetic_job(
        $run, $job, 'fail', $resource_name, aborted => $aborted,
    );
}

# Launch a synthesized skip/fail via the normal Collector path, using
# a perl -e one-liner instead of the real test file. Only job_limiter
# resources that are NOT permanent_broken get consulted (with a fixed
# need=1) -- the broken resource itself is of course skipped, and
# non-limiter resources don't participate in accounting for one-off
# synthetic runs.
#
# Returns 'launched', 'defer' (limiter full right now), or 'skip'
# (no usable limiter at all, so the synth launch can never run).
sub _launch_synthetic_job {
    my ($self, $run, $job, $kind, $resource_name, %opts) = @_;

    croak "synthetic kind must be 'skip' or 'fail' (got '$kind')"
        unless $kind eq 'skip' || $kind eq 'fail';

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
        $kind eq 'skip'
        ? 'use Test2::V0; skip_all($ARGV[0])'
        : 'die "$ARGV[0]\n"';
    my $launch = [$^X, '-Ilib', '-e', $script, '--', $reason];

    # Pull the job-limiter resources the scheduler would otherwise
    # have consulted. Permanent-broken ones (including the trigger)
    # are skipped; non-limiters don't participate -- a one-liner has
    # no real resource footprint and shouldn't hold onto e.g. a GPU
    # assignment.
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});
    my @limiters =
        grep { $_->is_job_limiter && !$_->is_permanent_broken && $_->needed(job => $job) } @all;

    # Availability gate: share the run's job-limiter pool with real
    # tests. If every usable limiter is saturated right now, defer
    # and let the scheduler re-try on the next tick once a slot frees.
    # If a limiter can never accommodate us (-1, which should not
    # happen with need=1 on a single-slot pool but is possible in
    # pathological configurations) the synth job is skipped outright.
    for my $res (@limiters) {
        my $av = $res->available(job => $job, min => 1, max => 1, need => 1);
        if ($av < 0) {
            $run->mark_skipped($job->job_id);
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
    #               ('skip')   - resource is present but cannot ever
    #                            grant (e.g. slot request > pool
    #                            size). Scheduler silently drops the
    #                            job from pending.
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

        my $av = $res->available(job => $job);
        return ('skip')  if $av < 0;
        return ('defer') if !$av;

        push @use => $res;
    }

    return ('launch', \@use);
}

sub _ensure_run_service_started {
    my ($self, $run) = @_;

    # String keys here match the HashBase +resources_started /
    # +resources_torn_down declarations on Test2::Harness2::Run -- the
    # constants are scoped to that package, but the attributes are just
    # idempotency flags, so touching the hash directly is fine.
    return if $run->{resources_started};
    $run->{resources_started} = 1;

    # In unit tests that exercise scheduler logic without building a
    # real IPC bus, ipcm_info is undef; skip the fork then so the
    # rest of the scheduler still works. Production code paths
    # (start/spawn) always set ipcm_info before this method runs.
    return unless defined $self->ipcm_info;

    my $run_id = $run->run_id;
    my $bus    = "run-$run_id";

    # Effective logger lists for this run: the harness's defaults,
    # possibly overridden or extended by the Run's own intent slots.
    # service_loggers flow to the RunService's own event output and
    # to resource services scoped to this run; test_loggers flow to
    # each per-job Collector launched inside the run.
    my $svc_loggers  = $run->effective_service_loggers($self->{+SERVICE_LOGGERS});
    my $test_loggers = $run->effective_test_loggers($self->{+TEST_LOGGERS});

    my $pid = Test2::Harness2::RunService->spawn(
        workdir      => $self->{+WORKDIR},
        logdir       => $self->{+LOGDIR},
        run          => $run,
        ipcm_info    => $self->ipcm_info,
        parent_pids  => [$$],
        harness_name => $self->{+NAME},
        loggers      => $svc_loggers,
        test_loggers => $test_loggers,
    );

    $self->{+RUN_SERVICES}->{$run_id} = {
        pid        => $pid,
        run        => $run,
        bus_name   => $bus,
        started_at => time,
    };

    return;
}

# Lazy-build an IPC handle to the run service, once we need to make a
# sync_request into it. Cached on the run-services entry so repeated
# launches reuse one handle.
sub _run_service_handle {
    my ($self, $run_id) = @_;

    my $entry = $self->{+RUN_SERVICES}->{$run_id}
        or croak "no run service tracked for run '$run_id'";

    return $entry->{_handle} //= IPC::Manager::Service::Handle->new(
        service_name => $entry->{bus_name},
        ipcm_info    => $self->ipcm_info,
    );
}

# Block briefly waiting for a newly-spawned run service to be ready
# to accept IPC requests. sync_request itself queues messages that
# arrive before the service is up, but the timeout behaviour is
# clearer if we wait explicitly.
sub _wait_for_run_service_ready {
    my ($self, $run_id) = @_;

    my $handle   = $self->_run_service_handle($run_id);
    my $deadline = time + 10;
    until ($handle->ready) {
        croak "timeout waiting for run service '$run_id' to come up"
            if time > $deadline;
        tinysleep(0.02);
    }
    return $handle;
}

# When a preload resource is configured, route launch_job to its
# bus name so the test runs in the preloaded interpreter. A preload
# that is not-yet-running, paused, or permanent_broken returns undef
# so the run service takes over.
#
# Stage 8 routing is deliberately simple: the first Preload resource
# in the harness's global resources list wins. Later stages with
# richer stage-assignment (HARNESS-STAGE-NAME directives, per-run
# preloads) will need a more specific selection rule; for now the
# single-preload-global-scope path is the only shape.
sub _preload_target_for {
    my ($self, $job, $resources) = @_;

    for my $res (@{$self->{+RESOURCES} // []}) {
        next unless $res->isa('Test2::Harness2::Resource::Preload');
        next if $res->is_permanent_broken;
        next if $res->is_broken;
        next if $res->is_paused;
        next unless $res->pid;                                            # service not up yet
        next unless $res->service_preload_applicable(harness => $self);

        return $res->service_name;
    }

    return undef;
}

# Generic "wait for $service_name to be ready on the bus" helper.
# Mirrors _wait_for_run_service_ready but takes the bus name directly
# so it can be used for preload services and any other non-run
# services the harness routes requests to.
sub _wait_for_service_ready {
    my ($self, $bus_name) = @_;

    my $handle = IPC::Manager::Service::Handle->new(
        service_name => $bus_name,
        ipcm_info    => $self->ipcm_info,
    );

    my $deadline = time + 10;
    until ($handle->ready) {
        croak "timeout waiting for service '$bus_name' to come up"
            if time > $deadline;
        tinysleep(0.02);
    }
    return $handle;
}

sub _teardown_run_service {
    my ($self, $run) = @_;

    # Called from three sites: _handle_job_complete (normal run
    # completion), _try_launch_next_pending (all-skipped completion),
    # and run_on_cleanup (runs left in the queue at shutdown). The
    # resources_torn_down flag below makes each call idempotent.
    return if $run->{resources_torn_down};
    $run->{resources_torn_down} = 1;

    my $rid = $run->run_id;
    my $svc = delete $self->{+RUN_SERVICES}->{$rid};
    return unless $svc;
    return unless $svc->{pid};

    # SIGTERM the run service. Its SIG{TERM} handler flips the service
    # state to 'terminating' and run_on_cleanup inside the child will
    # cascade TERMs to the run's resource services before exiting. The
    # reap lands on our side via IPC::Manager's waitpid tick and falls
    # through run_on_pid -- see the run-services guard there.
    kill TERM => $svc->{pid} if kill 0 => $svc->{pid};

    return;
}

sub _launch_job {
    my ($self, $run, $job, $resources, %opts) = @_;

    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    # First job of this run -- announce run_started before the job_started.
    $self->emit_service_event(
        kind     => 'run_started',
        run_data => {run_id => $run_id},
    ) if !@{$run->running} && !@{$run->done};

    $self->emit_service_event(
        kind     => 'job_started',
        job_info => {
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job->job_try,
        },
    );

    my $assign_id = gen_uuid();
    my %env;
    my %assign_args = %{$opts{assign_args} // {}};
    for my $res (@$resources) {
        $res->assign(id => $assign_id, job => $job, env => \%env, %assign_args);
    }

    # Decide which service handles the launch: a preload resource
    # (if present, usable, and not part of a synthetic launch) gets
    # priority so tests run in the preloaded interpreter. Otherwise
    # the per-run supervisor owns launch + reap + stdio logging. The
    # harness still owns scheduling (resources assigned above).
    my $preload_target = !$opts{launch} ? $self->_preload_target_for($job, $resources) : undef;

    my $launch_ok = eval {
        my $handle;
        my $target_bus;

        if (defined $preload_target) {
            $handle     = $self->_wait_for_service_ready($preload_target);
            $target_bus = $preload_target;
        }
        else {
            $handle     = $self->_wait_for_run_service_ready($run_id);
            $target_bus = "run-$run_id";
        }

        my $envelope = $handle->sync_request(
            $target_bus,
            {
                request      => 'launch_job',
                run_id       => $run_id,
                run_bus_name => "run-$run_id",
                job_id       => $job_id,
                job_try      => 0,
                test_file    => $job->test_file_abs,
                env          => \%env,
                auditor      => $self->{+TEST_AUDITOR},
                # Omit loggers from the payload: the run service uses
                # its own TEST_LOGGERS slot (populated at spawn from
                # the run's effective test_loggers) when the payload
                # doesn't override.
                (defined $opts{launch} ? (launch      => $opts{launch})         : ()),
                ($self->{+LAUNCH_ARGS} ? (launch_args => $self->{+LAUNCH_ARGS}) : ()),
            },
        );

        # IPC::Manager wraps request bodies in {response => ...}; our
        # actual handler return value lives inside that slot.
        my $resp = ref($envelope) eq 'HASH' ? $envelope->{response} : undef;
        die "launch_job rejected: " . (ref($resp) eq 'HASH' ? ($resp->{error} // '(no error given)') : '(no response)')
            unless ref($resp) eq 'HASH' && $resp->{ok};

        $run->mark_running($job_id);

        $self->{+RUNNING_JOBS}->{$job_id} = {
            run                => $run,
            job                => $job,
            pid                => $resp->{pid},
            started_at         => time,
            assign_id          => $assign_id,
            assigned_resources => $resources,
            log_file           => $resp->{log_file},
        };

        1;
    };
    my $launch_err = $@;

    unless ($launch_ok) {
        # Launch failed; release the resources we just committed so
        # their slots don't leak. The job never reached RUNNING_JOBS
        # so _release_job_resources won't reach it on its own.
        for my $res (@$resources) {
            my $rok  = eval { $res->release(id => $assign_id, job => $job); 1 };
            my $rerr = $@;
            warn "failed to release resource '" . $res->resource_name . "' after launch failure: $rerr"
                unless $rok;
        }
        die $launch_err;
    }

    return $job_id;
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
