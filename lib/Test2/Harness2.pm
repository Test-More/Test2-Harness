package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2::Util qw/parse_exit/;
use POSIX qw/WNOHANG getpgrp/;

use constant IS_WIN32            => $^O eq 'MSWin32';
use constant HAS_CHILD_SUBREAPER => eval {
    require Test2::Harness2::ChildSubReaper;
    Test2::Harness2::ChildSubReaper::have_subreaper_support() ? 1 : 0;
} || 0;

use Atomic::Pipe;
use IPC::Manager qw/ipcm_spawn/;
use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Resource::JobCount;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Run;
use Test2::Harness2::RunService;
use Test2::Harness2::Util::EventEmitter;
use Test2::Harness2::Util::IPC qw/list_direct_children/;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <job_id
    <loggers
    <test_auditor
    <test_loggers
    <kill_timeout
    <parent_pids
    <jump_to
    <resources
    +state
    +queue
    +running_jobs
    +resource_services
    +run_services
    +finish_after_initial_run
    +emitter
    +watch_pids_ref
    +own_pgroup
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Resource-service log files live under the harness's logdir
# ($workdir/logs/ by default), not directly under $workdir.
sub _service_host_logdir { $_[0]->{+LOGDIR} }

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
    $self->{+WATCH_PIDS_REF}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    $self->_init_resources;

    # TODO: Eventually we will remove this default, but wait until we write the
    # App::Yath2 code for that. No immediate action, but leave this TODO for
    # future reference.
    $self->{+LOGGERS} //= [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$logdir/services/$self->{+NAME}.jsonl",
        ],
        [
            'Test2::Harness2::Collector::Logger::JSON',
            output_file => "$logdir/services/$self->{+NAME}.json",
            spec        => $self,
        ],
    ];
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
    $self->{+TEST_LOGGERS} //= ['Test2::Harness2::Collector::Logger::JSONL'];
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

    Test2::Harness2::Collector->interpose(
        ipcm_info   => $self->ipcm_info,
        ipc_peer    => $self->{+NAME},
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

            sleep(0.02);
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

# IPC::Manager::Role::Service required methods. Fleshed out in later tasks.
sub orig_io    { {} }
sub ipcm_info  { $_[0]->{ipcm_info} }
sub pid        { $_[0]->{pid} //= $$ }
sub set_pid    { $_[0]->{pid} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

# IPC::Manager calls handle_request($req, $msg) where $req is the full
# message envelope: { ipcm_request_id => '...', request => $payload }.
# When called via Spawn->_send_request the payload is a hashref
# { request => $name, ...extra_fields... }.  We unwrap it so that
# $payload->{request} is the dispatch name and the extra fields are
# available for the individual handlers.
sub handle_request {
    my ($self, $req, $msg) = @_;

    # Unwrap the IPC::Manager envelope: $req->{request} is our payload.
    my $payload = $req->{request};
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};

    return {ok => 0, error => "missing request type"} unless defined $type;

    my $handler = "request_handler_$type";
    return $self->$handler($payload) if $self->can($handler);

    return {ok => 0, error => "unknown request '$type'"};
}

sub request_handler_queue_test_run {
    my ($self, $payload) = @_;
    $payload //= {};

    return {ok => 0, error => 'service not accepting new runs'}
        if $self->{+STATE} ne 'running';

    my $files = $payload->{files} || [];
    return {ok => 0, error => "'files' must be a non-empty arrayref"}
        unless ref($files) eq 'ARRAY' && @$files;

    my $run = Test2::Harness2::Run->from_files(
        files => $files,
        (defined $payload->{run_id} ? (run_id => $payload->{run_id}) : ()),
    );

    push @{$self->{+QUEUE}} => $run;

    $self->_emit_service_event(
        kind     => 'run_queued',
        run_data => $run->TO_JSON,
    );

    for my $job (@{$run->jobs}) {
        $self->_emit_service_event(
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

sub request_handler_terminate {
    my $self = shift;
    $self->_perform_hard_stop;
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
        if defined $kind && $kind eq 'job_complete';

    return $self->_handle_resource_state_message($kind, $content)
        if defined $kind && $kind =~ m/^resource_(?:paused|resumed|ready|broken|permanent_broken)$/;

    if (defined $kind && $kind eq 'loggers_ready') {
        # Each job's collector reports its logger metadata after startup so
        # the service can record where the job's outputs live.
        $self->_emit_service_event(
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

sub _handle_job_complete {
    my ($self, $content) = @_;

    my $job_id = ref($content) eq 'HASH' ? $content->{job_id} : undef;
    return unless defined $job_id;

    my $cur = delete $self->{+RUNNING_JOBS}->{$job_id};
    return unless $cur;

    # The run service reports exit in the IPC payload (a raw wait status).
    # Parse it once, then emit a job_completed lifecycle event for any
    # listeners following the harness's own log.
    my $raw_exit = ref($content) eq 'HASH' ? $content->{exit} : undef;
    my $exit     = defined($raw_exit) ? parse_exit($raw_exit) : undef;
    my $pass     = defined($exit) && $exit->{err} == 0 && $exit->{sig} == 0 ? 1 : 0;

    $self->_emit_service_event(
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
    $cur->{run}->mark_done($job_id);

    if ($cur->{run}->is_complete) {
        my $run    = $cur->{run};
        my $run_id = $run->run_id;
        $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];

        $self->_teardown_run_service($run);

        $self->_emit_service_event(
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

sub _perform_hard_stop {
    my $self = shift;

    # NOTE: this method kills processes and clears scheduler state; it
    # does NOT call teardown() on any resources. Callers that want a
    # clean shutdown must invoke run_on_cleanup (or call
    # _teardown_run_service explicitly for any per-run resources
    # they care about) after this returns.
    $self->{+STATE} = 'terminating';
    $self->{+QUEUE} = [];

    my $grace = $self->{+KILL_TIMEOUT};

    # %pids maps each tracked pid to a hashref recording which signals
    # we have already sent it and when:
    #   $pids{$pid} = { TERM => $t1 }           # first-signal stage
    #   $pids{$pid} = { TERM => $t1, KILL => $t2 }  # escalated to KILL
    # An empty hashref means "tracked, but no signal sent yet" -- the
    # state newly-reparented descendants arrive in. The timestamps let
    # the loop tell "just KILL'd, give it a moment" from "KILL'd long
    # ago and still alive -- stuck past signal reach".
    my %pids;

    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $pids{$cur->{pid}} //= {} if $cur->{pid};
    }

    # Add any registered workers.
    if ($self->can('workers')) {
        $pids{$_} //= {} for keys %{$self->workers // {}};
    }

    # Add any resource-service pids.
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    # Add any run-service pids. A run service's own SIG{TERM} handler
    # cascades the TERM down to its per-run resource services before
    # the service loop unwinds, so they'll be taken down by their own
    # run service when we signal it here.
    for my $info (values %{$self->{+RUN_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    # Drop CURRENT/workers that IPC::Manager's per-tick waitpid may
    # have reaped before _perform_hard_stop ran. Only one sweep is
    # needed: from here on Perl runs synchronously and no other code
    # path in the service reaps children behind us. Descendants
    # reparented via PR_SET_CHILD_SUBREAPER aren't populated here --
    # the loop below enumerates them on every iteration (via /proc,
    # falling back to ps) and the first iteration catches whatever
    # set is live at entry, so pre-loading them would be redundant.
    delete $pids{$_} for grep { !kill(0, $_) } keys %pids;

    my $first_sig = IS_WIN32 ? 'INT' : 'TERM';

    while (1) {
        # Pick up any descendants that have reparented to us since the
        # last pass -- freshly-enumerated on the first iteration, and
        # any newcomers from a just-reaped parent on later iterations.
        # They arrive with an empty signal map so they get the full
        # first-signal grace window rather than inheriting the state
        # of the layer above them.
        if (HAS_CHILD_SUBREAPER) {
            $pids{$_} //= {} for list_direct_children($$);
        }

        my (@fresh, @to_kill, $unignored);
        for my $pid (keys %pids) {
            my $state = $pids{$pid};

            next if $state->{IGNORE};

            $unignored++;

            if (my $f_ts = $state->{$first_sig}) {
                if (my $k_ts = $state->{KILL}) {
                    my $delta = time - $k_ts;

                    if ($delta >= $grace) {
                        $state->{IGNORE} = 1;
                        $unignored--;
                    }
                }
                elsif ((time - $f_ts) >= $grace) {
                    # Times up, time to kill
                    push @to_kill => $pid;
                }
            }
            else {
                # New, need first signal
                push @fresh => $pid;
            }
        }

        # If unignored is 0 then we have no pids that need action now or in the future.
        last unless $unignored;

        # Send the first signal to anything that has not had one. All
        # workers are spawned with new_pgroup => 1 so each is already
        # in its own pgroup; we signal by pid rather than by pgroup,
        # which avoids accidentally signalling the service itself.
        if (@fresh) {
            kill($first_sig => @fresh);
            my $now = time;
            $pids{$_}{$first_sig} = $now for @fresh;
        }

        if (@to_kill) {
            kill(KILL => @to_kill);
            my $now = time;
            $pids{$_}{KILL} = $now for @to_kill;
        }

        # Reap whatever is ready.
        my $reaped = 0;
        while (my $pid = waitpid(-1, WNOHANG)) {
            last if $pid < 1;
            delete $pids{$pid};
            $reaped = 1;
        }

        # Sleep unless we did something.
        sleep(0.05) unless $reaped || @fresh || @to_kill;
    }

    # Drop all tracked running jobs; their pids are either gone or being
    # ignored. _release_job_resources makes a best-effort release on each.
    for my $cur (values %{$self->{+RUNNING_JOBS} // {}}) {
        $self->_release_job_resources($cur);
    }
    $self->{+RUNNING_JOBS}      = {};
    $self->{+RESOURCE_SERVICES} = {};
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
    # service would have sent job_complete first; only reach this branch
    # if that didn't happen. Release resources and mark the job done so
    # the scheduler doesn't wait forever.
    for my $job_id (keys %{$self->{+RUNNING_JOBS} // {}}) {
        my $cur = $self->{+RUNNING_JOBS}->{$job_id};
        next unless $cur->{pid} && $cur->{pid} == $pid;

        warn "Test2::Harness2: orphaned test pid $pid exited with $exit (job $job_id); " . "its run service died before reporting\n";
        $self->_handle_job_complete({
            kind   => 'job_complete',
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
    $self->_handle_resource_service_exit($pid, $exit);

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

sub run_on_start {
    my $self = shift;

    # Own our pgroup so tests that kill their own pgroups can't reach us.
    # _perform_hard_stop still signals by pid, not by pgroup, to avoid
    # hitting the service itself.
    if (POSIX::setpgid(0, 0)) {
        $self->{+OWN_PGROUP} = 1;
    }
    else {
        warn "setpgid(0,0) failed in run_on_start: $!";
    }

    # Ask the kernel to treat us as a subreaper (Linux >= 3.4 only).
    # Effect: any descendant that gets orphaned (its immediate parent
    # died, typically because a test double-forked or called setsid +
    # exit on its parent) reparents to THIS process instead of init(1).
    #
    # Once reparented, those processes become our direct children for
    # all kernel purposes. Ongoing bookkeeping falls to two pieces:
    #
    #   * Reaping: IPC::Manager's service loop runs waitpid(-1, WNOHANG)
    #     every tick and forwards each non-worker pid to run_on_pid().
    #     Our run_on_pid() recognizes the currently-tracked collector
    #     pid and hands its exit status to the collector Handle;
    #     anything else is a reparented descendant that's already been
    #     drained.
    #
    #   * Termination at shutdown: pgroups do not follow reparenting,
    #     so _perform_hard_stop also enumerates our direct children
    #     (via /proc, falling back to ps) and folds any extras into
    #     the TERM-then-KILL sequence. That enumeration only runs at
    #     shutdown; the per-tick reap is handled in-loop by
    #     IPC::Manager.
    #
    # Test2::Harness2::ChildSubReaper is an optional dep. On non-Linux
    # or when the module is not installed, we skip silently -- the
    # harness still works, we just lose the escape-hatch cleanup for
    # detached grandchildren.
    if (HAS_CHILD_SUBREAPER) {
        Test2::Harness2::ChildSubReaper::set_child_subreaper(1)
            or warn "set_child_subreaper failed: $!";
    }

    # First structured event: service is up.
    $self->_emit_service_event(
        kind    => 'service_started',
        pid     => $$,
        pgid    => getpgrp(),
        name    => $self->{+NAME},
        workdir => $self->{+WORKDIR},
    );

    $self->_start_resource_services($self->{+RESOURCES}, scope => 'global');
}

sub run_on_cleanup {
    my $self = shift;

    # Snapshot the queue so we can tear down per-run resources for any
    # runs that didn't complete cleanly -- _perform_hard_stop drains the
    # queue before returning.
    my @leftover_runs = @{$self->{+QUEUE} // []};

    my $has_running = keys %{$self->{+RUNNING_JOBS} // {}};
    $self->_perform_hard_stop if $has_running || @{$self->{+QUEUE}};

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

    $self->_emit_service_event(kind => 'service_stopped');
}

sub _emit_service_event {
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

    # Job completion is driven by the job_complete IPC message the run
    # services send when a test collector exits (see _handle_job_complete).
    # Here we only drive the scheduler forward.
    return if $self->{+STATE} eq 'terminating';

    # Launch as many pending jobs as the active resources permit this tick.
    1 while $self->_try_launch_next_pending;
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

            my ($decision, $use_res) = $self->_evaluate_resources_for($run, $job);

            if ($decision eq 'skip') {
                # The resource set can never satisfy this job. Drop it
                # from pending; real skip-result events are left for the
                # follow-on scheduler work.
                $run->mark_skipped($job_id);
                if ($run->is_complete) {
                    my $rid = $run->run_id;
                    $self->{+QUEUE} = [grep { $_->run_id ne $rid } @{$self->{+QUEUE}}];
                    $self->_teardown_run_service($run);
                    $self->{+STATE} = 'finishing'
                        if $self->{+FINISH_AFTER_INITIAL_RUN}
                        && $self->{+STATE} eq 'running';
                }
                return 1;
            }

            next if $decision eq 'defer';

            $self->_launch_job($run, $job, $use_res);
            return 1;
        }
    }

    return 0;
}

sub _evaluate_resources_for {
    my ($self, $run, $job) = @_;

    # Global resources are consulted first, then per-run resources layered
    # on top. Either set may defer or skip; all-or-nothing commitment is
    # preserved because we only call assign() in _launch_job after the
    # entire walk returns ('launch', \@use).
    my @all = (@{$self->{+RESOURCES}}, @{$run->resources // []});

    my @use;
    for my $res (@all) {
        next unless $res->applicable(job => $job);

        # A permanently-broken resource can never satisfy this job.
        return ('skip') if $res->is_permanent_broken;

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
    my $pid    = Test2::Harness2::RunService->spawn(
        workdir      => $self->{+WORKDIR},
        logdir       => $self->{+LOGDIR},
        run          => $run,
        ipcm_info    => $self->ipcm_info,
        parent_pids  => [$$],
        harness_name => $self->{+NAME},
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
        sleep(0.02);
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
    my ($self, $run, $job, $resources) = @_;

    my $run_id = $run->run_id;
    my $job_id = $job->job_id;

    # First job of this run -- announce run_started before the job_started.
    $self->_emit_service_event(
        kind     => 'run_started',
        run_data => {run_id => $run_id},
    ) if !@{$run->running} && !@{$run->done};

    $self->_emit_service_event(
        kind     => 'job_started',
        job_info => {
            run_id  => $run_id,
            job_id  => $job_id,
            job_try => $job->job_try,
        },
    );

    my $assign_id = gen_uuid();
    my %env;
    for my $res (@$resources) {
        $res->assign(id => $assign_id, job => $job, env => \%env);
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
                loggers   => [],                       # run service adds its own loggers
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
