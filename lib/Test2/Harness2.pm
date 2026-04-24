package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/parse_exit tinysleep load_module/;
use POSIX qw/WNOHANG/;

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
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

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
    <broken_resource_behavior
    state
    +queue
    +scheduler
    +running_jobs
    <resource_services
    +run_services
    +completed_runs
    +finish_after_initial_run
    +emitter
    +artifacts
    watch_pids
    own_pgroup
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
    $self->{+SCHEDULER}         //= {};
    $self->{+RUNNING_JOBS}      //= {};
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+RUN_SERVICES}      //= {};
    $self->{+COMPLETED_RUNS}    //= {};
    $self->{+WATCH_PIDS}        //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;
    $self->{+ARTIFACTS}         //= {};

    $self->{+BROKEN_RESOURCE_BEHAVIOR} //= 'skip';
    croak "invalid broken_resource_behavior '$self->{+BROKEN_RESOURCE_BEHAVIOR}' (want skip, fail, or abort)"
        unless BROKEN_BEHAVIORS->{$self->{+BROKEN_RESOURCE_BEHAVIOR}};

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
    # Top-of-tree interpose: no ipc_parent means the Service
    # subclass's builder cannot derive a bus_id, so pass one
    # explicitly. The collector identifies by the harness's own
    # bus name.
    require Test2::Harness2::Collector::Service::Harness;
    Test2::Harness2::Collector::Service::Harness->interpose(
        ipcm_info    => $self->ipcm_info,
        ipc_parent   => undef,
        ipc_run      => undef,
        ipc_harness  => $self->{+NAME},
        bus_id       => "collector:" . $self->{+NAME},
        logdir       => $self->{+LOGDIR},
        service_name => $self->{+NAME},
        loggers      => $loggers,
        parser       => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids  => [$caller_pid],
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
        $self->_scheduler_queue_run($run);
        1;
    };
    my $err = $@;
    return {ok => 0, error => "$err"} unless $ok;

    my $run = $self->{+QUEUE}->[-1];

    $self->emit_service_event(
        kind     => 'run_queued',
        run_data => $run->TO_JSON,
    );

    # job_queued events are emitted by the run service once it has
    # started, so the per-job lifecycle stream lives in the run's own
    # .jsonl and not in the harness's service log.

    return {ok => 1, run_id => $run->run_id};
}

sub request_handler_status {
    my $self = shift;

    my $queue = [
        map { {
            run_id  => $_->run_id,
            pending => [@{$_->pending}],
            running => [@{$_->running}],
            done    => [@{$_->done}],
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

sub request_handler_finish {
    my $self = shift;
    return {ok => 0} unless $self->{+STATE} eq 'running';
    $self->{+STATE} = 'finishing';
    return {ok => 1};
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
    return $self->_handle_run_state_update($content)
        if defined $kind && $kind eq 'run_state_update';

    # Run-service aggregation: per-job release signal. The scheduler
    # needs resource release and a wake-up; the final verdict already
    # flowed through the run_state_update channel (and is logged in
    # the run's own jsonl, not here).
    return $self->_handle_job_release($content)
        if defined $kind && $kind eq 'job_release';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    # Run-scoped collector_artifacts (run_id defined) flow to the run
    # service, which logs them as job_loggers on the run's own emitter.
    # Global collector_artifacts (no run_id -- e.g. from a resource-
    # service collector) are handled here: merged into %artifacts and
    # flushed to logs/artifacts.json.
    if (defined $kind && $kind eq 'collector_artifacts') {
        return $self->_handle_global_collector_artifacts($content)
            unless defined $content->{run_id};
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

sub _seed_artifacts_from_loggers {
    my $self = shift;

    # Harness LOGGERS are final after service init: no logger added or
    # removed after this point reaches the harness's own interpose
    # collector (already forked). We build metadata eagerly here so the
    # global artifacts.json reflects the full configured logger set,
    # including arrayref specs ([$class, %args]) which the collector
    # child otherwise instantiates independently in its own process.
    for my $item (@{$self->{+LOGGERS} // []}) {
        my $inst = $self->_logger_instance_for_metadata($item) or next;
        next unless $inst->can('metadata');
        $inst->prepare_output_locations;
        my $meta = $inst->metadata;
        next unless ref($meta) eq 'HASH';
        $self->_merge_artifacts({ref($inst) => [$meta]});
    }

    $self->_write_artifacts_manifest;
    return;
}

# Return an instance suitable for calling metadata()/prepare_output_locations.
# Blessed specs are returned as-is. Arrayref specs are instantiated with
# harness-scope identity so metadata() resolves output paths the same way
# the interpose collector's own instantiation would. This does not open
# file handles (loggers defer that to startup()), so it is fork-safe.
sub _logger_instance_for_metadata {
    my ($self, $item) = @_;

    return $item if blessed($item);
    return undef unless ref($item) eq 'ARRAY';

    my ($class, @args) = @$item;

    my %identity = (
        logdir       => $self->{+LOGDIR},
        service_name => $self->{+NAME},
        ipcm_info    => $self->ipcm_info,
    );

    my $inst;
    my $ok  = eval { load_module($class); $inst = $class->new(%identity, @args); 1 };
    my $err = $@;
    unless ($ok) {
        warn "Test2::Harness2: failed to pre-instantiate logger '$class' for metadata: $err";
        return undef;
    }

    return $inst;
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
                    warn "Test2::Harness2: artifact '$rel' already claimed by $artifacts->{$rel}, ignoring duplicate from $class\n";
                    next;
                }
                $artifacts->{$rel} = $class;
            }
        }
    }

    return;
}

sub _write_artifacts_manifest {
    my $self = shift;

    my $path = "$self->{+LOGDIR}/artifacts.json";

    my $ok  = eval { write_json_file_atomic($path, $self->{+ARTIFACTS}); 1 };
    my $err = $@;
    warn "Test2::Harness2: failed to write $path: $err" unless $ok;

    return;
}

sub _handle_global_collector_artifacts {
    my ($self, $content) = @_;

    $self->_merge_artifacts($content->{loggers} // {});
    $self->_write_artifacts_manifest;
    return;
}

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS}}];
    return {ok => 1};
}

# Run-service aggregation: replace our mirror Run's pending /
# running / done lists with the run service's authoritative
# snapshot. When that replacement closes the run out (nothing
# pending, nothing running), tear down the run service and emit
# run_ended.
#
# run_data is the full Run->TO_JSON payload; we reach into the
# shadow Run and overwrite just the three lists so any other fields
# the harness stamped at queue time (resources objects, logger
# intent slots, launch_job_timeout) survive. Resources in
# particular are live Perl objects that cannot round-trip through
# JSON.
sub _handle_run_state_update {
    my ($self, $content) = @_;
    return unless ref($content) eq 'HASH';

    my $run_id = $content->{run_id};
    my $data   = $content->{run_data};
    return unless defined $run_id && ref($data) eq 'HASH';

    my ($run) = grep { $_->run_id eq $run_id } @{$self->{+QUEUE} // []};
    return unless $run;

    for my $slot (qw/pending running done/) {
        my $list = $data->{$slot};
        next unless ref($list) eq 'ARRAY';
        $run->{$slot} = [@$list];
    }

    if (ref($data->{results}) eq 'HASH') {
        $run->{results} = {%{$data->{results}}};
    }

    # Finalization is scheduler-driven: only consider the run done
    # when the scheduler has both no pending jobs and no running
    # jobs of its own. The Run mirror's is_complete is informational.
    $self->_finalize_run_if_complete($run);

    return;
}

# Build the "final" snapshot stashed into COMPLETED_RUNS so that
# callers can query pass/fail via IPC after a run ends but before
# the harness itself exits. Aggregate pass is true when every job
# that reported a result passed; skipped jobs have no result entry
# and therefore do not fail the aggregate.
sub _snapshot_run_results {
    my ($self, $run) = @_;

    my $results  = $run->results // {};
    my $all_pass = 1;
    for my $jid (keys %$results) {
        # Entries without completed_at are queue-time or started-time
        # seeds (jobs that never finished or were skipped). Only
        # completed jobs contribute to the aggregate verdict.
        next unless defined $results->{$jid}{completed_at};
        $all_pass = 0 unless $results->{$jid}{pass};
    }

    return {
        run_id  => $run->run_id,
        state   => 'complete',
        pass    => $all_pass ? 1 : 0,
        results => {%$results},
        done    => [@{$run->done}],
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

    my $run_id = $cur->{run}->run_id;
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
    # service's watchdog would synthesize completion for us and emit
    # run_state_update + job_release; only reach this branch if its
    # whole process went away without unwinding. Release resources
    # and mark the job done on the mirror Run so the scheduler doesn't
    # wait forever.
    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        warn "Test2::Harness2: orphaned test pid $pid exited with $exit (job $job_id); " . "its run service died before reporting\n";

        my $run = $cur->{run};
        delete $self->{+RUNNING_JOBS}->{$job_id};
        $self->_release_job_resources($cur);
        $self->_scheduler_mark_done($run->run_id, $job_id);

        $self->_finalize_run_if_complete($run);

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
    $self->_seed_artifacts_from_loggers;
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
    $s->{pending} = [grep { $_ ne $job_id } @{$s->{pending}}];
    $s->{running}->{$job_id} = 1;
    $s->{started} = 1;
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

    # Runs are processed serially in the order they were queued.
    # The scheduler iterates QUEUE (an ordered arrayref) and finds
    # the first run that is not yet complete from the scheduler's
    # perspective; that becomes the head run for this tick. Other
    # queued runs are not even considered until the head run has
    # drained its own pending+running. We never run a later run
    # ahead of an earlier one.
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

    # Iterate the scheduler's own pending list, not $run->pending.
    # The scheduler's list is the authoritative view of what we
    # have not yet attempted to launch; $run->pending mirrors
    # the run service and can lag behind reality.
    for my $job_id (@{$self->_scheduler_pending_for_run($run_id)}) {
        my ($job) = grep { $_->job_id eq $job_id } @{$head_run->jobs};
        next unless $job;

        # Run-level abort state (see _handle_broken_resource):
        # once a run is aborted, every remaining job takes the
        # synthetic-fail path, whether or not that specific job
        # needed the broken resource. The aborted flag on the
        # decision distinguishes the original trigger (aborted=0)
        # from follow-ups swept up by the abort (aborted=1).
        my ($decision, $arg, %dec_opts);
        if (defined $head_run->{aborted_reason}) {
            ($decision, $arg) = ('broken', $head_run->{aborted_reason});
            $dec_opts{aborted} = 1;
        }
        else {
            ($decision, $arg) = $self->_evaluate_resources_for($head_run, $job);
        }

        if ($decision eq 'skip') {
            # The resource set can never satisfy this job. Drop
            # it from the scheduler's pending; no synthesized
            # completion event (this is not a failure, the job
            # just could not run).
            $self->_scheduler_skip($run_id, $job_id);
            $self->_finalize_run_if_complete($head_run);
            return 1;
        }

        if ($decision eq 'broken') {
            # A needed resource has been permanently broken (or
            # the run has been aborted wholesale).
            # broken_resource_behavior decides how the job is
            # dispatched; the synth launch shares the job-limiter
            # pool and may defer if the pool is saturated.
            my $outcome = $self->_handle_broken_resource($head_run, $job, $arg, %dec_opts);
            return 1 if $outcome eq 'launched' || $outcome eq 'skip';
            next;    # 'defer' -- try the next job in this run
        }

        next if $decision eq 'defer';

        $self->_launch_job($head_run, $job, $arg);
        return 1;
    }

    return 0;
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
    return unless $run->is_complete;

    # Idempotent: if we already finalized this run, do nothing.
    return if $self->{+COMPLETED_RUNS}->{$run_id};

    $self->{+COMPLETED_RUNS}->{$run_id} = $self->_snapshot_run_results($run);
    $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];
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
        kill_timeout => $self->{+KILL_TIMEOUT},
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
#
# The original hardcoded 10s cap assumed Linux-container scheduling
# where IPC sockets bind essentially instantly. That assumption
# breaks on macOS and intermittently on slower CI containers -- see
# issue #392. Default raised to 60s and made env-overridable via
# YATH_RUN_SERVICE_READY_TIMEOUT so contributors on slower hosts
# can tune without a source patch.
sub _wait_for_run_service_ready {
    my ($self, $run_id) = @_;

    my $handle   = $self->_run_service_handle($run_id);
    my $cap      = $ENV{YATH_RUN_SERVICE_READY_TIMEOUT} // 60;
    my $deadline = time + $cap;
    until ($handle->ready) {
        croak "timeout waiting for run service '$run_id' to come up after ${cap}s"
            if time > $deadline;
        tinysleep(0.02);
    }
    return $handle;
}

sub _teardown_run_service {
    my ($self, $run) = @_;

    # Called from three sites: _handle_run_state_update (normal run
    # completion observed via the run service's aggregated snapshot),
    # _try_launch_next_pending (all-skipped completion), and
    # run_on_cleanup (runs left in the queue at shutdown). The
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

    # First job of this run -- announce run_started. The per-job
    # job_started event is emitted by the run service now (fired
    # from its TestObserver aggregation path), so the harness log
    # only carries the run-level lifecycle bracket.
    $self->emit_service_event(
        kind     => 'run_started',
        run_data => {run_id => $run_id},
    ) unless $self->_scheduler_started($run_id);

    my $assign_id = gen_uuid();
    my %env;
    my %assign_args = %{$opts{assign_args} // {}};
    for my $res (@$resources) {
        $res->assign(id => $assign_id, job => $job, env => \%env, %assign_args);
    }

    # Delegate the actual Collector fork to the per-run supervisor so
    # the test process runs under the run's subtree. The harness owns
    # scheduling (resources assigned above) and the run service owns
    # launch + reap + stdio logging.
    my $launch_ok = eval {
        my $handle = $self->_wait_for_run_service_ready($run_id);

        my $envelope = $handle->sync_request(
            "run-$run_id",
            {
                request   => 'launch_job',
                run_id    => $run_id,
                job_id    => $job_id,
                job_try   => 0,
                test_file => $job->test_file_abs,
                env       => \%env,
                auditor   => $self->{+TEST_AUDITOR},
                # Omit loggers from the payload: the run service uses
                # its own TEST_LOGGERS slot (populated at spawn from
                # the run's effective test_loggers) when the payload
                # doesn't override.
                (defined $opts{launch} ? (launch => $opts{launch}) : ()),
            },
        );

        # IPC::Manager wraps request bodies in {response => ...}; our
        # actual handler return value lives inside that slot.
        my $resp = ref($envelope) eq 'HASH' ? $envelope->{response} : undef;
        die "launch_job rejected: " . (ref($resp) eq 'HASH' ? ($resp->{error} // '(no error given)') : '(no response)')
            unless ref($resp) eq 'HASH' && $resp->{ok};

        $self->_scheduler_mark_running($run_id, $job_id);

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
