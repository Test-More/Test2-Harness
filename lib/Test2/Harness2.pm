package Test2::Harness2;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX qw/WNOHANG getpgrp/;

use constant IS_WIN32 => $^O eq 'MSWin32';
use constant HAS_CHILD_SUBREAPER => eval {
    require Test2::Harness2::ChildSubReaper;
    Test2::Harness2::ChildSubReaper::have_subreaper_support() ? 1 : 0;
} || 0;

use Atomic::Pipe;
use IPC::Manager qw/ipcm_spawn/;
use Test2::Harness2::Collector;
use Test2::Harness2::Run;
use Test2::Harness2::Util::EventEmitter;
use Test2::Harness2::Util::IPC qw/list_direct_children/;

use Object::HashBase qw{
    <workdir
    <name
    <job_id
    <loggers
    <test_auditor
    <test_loggers
    <kill_timeout
    <parent_pids
    <jump_to
    <preload
    +preloader_pid
    +preloader_name
    +state
    +queue
    +current
    +finish_after_initial_run
    +emitter
    +watch_pids_ref
    +own_pgroup
};

use Role::Tiny::With;
with 'IPC::Manager::Role::Service';

sub init {
    my $self = shift;

    my $wd = $self->{+WORKDIR} // croak "'workdir' is a required attribute";
    croak "workdir '$wd' does not exist or is not a directory" unless -d $wd;
    croak "workdir '$wd' already contains services/ -- refusing to clobber"
        if -e "$wd/services";
    croak "workdir '$wd' already contains runs/ -- refusing to clobber"
        if -e "$wd/runs";

    make_path("$wd/services");

    $self->{+NAME}           //= 'harness';
    $self->{+JOB_ID}         //= gen_uuid();
    $self->{+KILL_TIMEOUT}   //= 15;
    $self->{+PARENT_PIDS}    //= [];
    $self->{+STATE}          //= 'running';
    $self->{+QUEUE}          //= [];
    $self->{+WATCH_PIDS_REF} //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}     //= 0;

    $self->{+LOGGERS} //= [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$wd/services/$self->{+NAME}.jsonl",
        ],
    ];
    $self->{+TEST_AUDITOR} //= 'Test2::Harness2::Collector::Auditor::Test';
    $self->{+TEST_LOGGERS} //= ['Test2::Harness2::Collector::Logger::JSONL'];

    # Preload configuration is accepted here but the preloader subprocess
    # is not started until run_on_start(): it has to fork from the service
    # process, not the spawn()-caller.
    $self->{+PRELOAD}         //= [];
    $self->{+PRELOADER_NAME}  //= 'preloader';
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
    # $workdir/services/ and populates default loggers.
    my $self = $class->new(%args);

    # Grab the loggers to hand to interpose before forking.
    my $loggers = $self->{+LOGGERS};

    # Everything the interpose child needs to do after the pipes are wired up
    # is packaged here so it can either run inline (the normal path) or be
    # handed to a caller-provided Long::Jump point via jump_to.
    my $run_service = sub {
        my $stdout_apipe = Atomic::Pipe->from_fh('>&=', \*STDOUT);
        $stdout_apipe->set_mixed_data_mode();
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->new(
            pipe   => $stdout_apipe,
            job_id => $self->job_id,
        );

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

    my $running;
    if (my $cur = $self->{+CURRENT}) {
        $running = {
            run_id    => $cur->{run}->run_id,
            job_id    => $cur->{job}->job_id,
            test_file => $cur->{job}->test_file,
            pid       => $cur->{pid},
            started   => $cur->{started_at},
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
        queue   => $queue,
        running => $running,
    };
}

sub request_handler_launch_test_in_preload {
    my ($self, $payload) = @_;

    my $stage = $payload->{stage};
    return {ok => 0, error => "'stage' is required"}
        unless defined $stage && length $stage;

    my $test_file = $payload->{test_file};
    return {ok => 0, error => "'test_file' is required"}
        unless defined $test_file && length $test_file;

    return {ok => 0, error => "no preloader configured"}
        unless $self->{+PRELOADER_PID};

    my $ok = eval {
        require IPC::Manager::Service::Handle;
        1;
    };
    return {ok => 0, error => "IPC::Manager::Service::Handle unavailable: $@"}
        unless $ok;

    my $handle = IPC::Manager::Service::Handle->new(
        service_name => $stage,
        ipcm_info    => $self->ipcm_info,
    );

    return {ok => 0, error => "stage '$stage' is not ready"} unless $handle->ready;

    # Defaults: hand the preloaded test the same auditor and logger
    # classes the inline-launch path uses. Loggers are specified as
    # [class, key => value] tuples so they round-trip cleanly through
    # IPC serialisation.
    my $run_id  = $payload->{run_id}  // gen_uuid();
    my $job_id  = $payload->{job_id}  // gen_uuid();
    my $job_try = $payload->{job_try} // 0;

    my $default_log_dir = join '/', $self->{+WORKDIR}, 'runs', $run_id, $job_id;
    make_path($default_log_dir);

    my $loggers = $payload->{loggers} // [
        [
            $self->{+TEST_LOGGERS}[0],
            output_file => "$default_log_dir/0.jsonl",
        ],
        [
            'Test2::Harness2::Collector::Logger::IPCNotify',
            service_name => $self->{+NAME},
        ],
    ];

    my $auditor = exists $payload->{auditor}
        ? $payload->{auditor}
        : $self->{+TEST_AUDITOR};

    my $resp = $handle->sync_request($stage, {
        request   => 'launch_test',
        test_file => $test_file,
        loggers   => $loggers,
        auditor   => $auditor,
        run_id    => $run_id,
        job_id    => $job_id,
        job_try   => $job_try,
        (exists $payload->{env}    ? (env    => $payload->{env})    : ()),
        (exists $payload->{argv}   ? (argv   => $payload->{argv})   : ()),
        (exists $payload->{parser} ? (parser => $payload->{parser}) : ()),
    });

    my $r = $resp->{response};
    return {
        %$r,
        run_id => $run_id,
        job_id => $job_id,
        stage  => $stage,
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

    if (defined $kind && $kind eq 'job_complete_notify') {
        # The act of receiving this message has already woken the service's
        # event loop. On the next run_on_all iteration, _check_current_completion
        # will detect the completion via waitpid. Nothing else to do.
        return;
    }

    warn "Test2::Harness2: unhandled general message kind: " . (defined $kind ? "'$kind'" : '(none)') . "\n";

    return;
}

sub request_handler_detach {
    my ($self, $payload) = @_;
    my $pid = $payload->{pid};
    return {ok => 0, error => "missing 'pid'"} unless defined $pid;

    $self->{+WATCH_PIDS_REF} = [grep { $_ != $pid } @{$self->{+WATCH_PIDS_REF}}];
    return {ok => 1};
}

sub _check_current_completion {
    my $self = shift;
    my $cur  = $self->{+CURRENT} or return;

    my $handle = $cur->{handle};
    return unless $handle->is_done;

    # Move the job from running to done.
    $cur->{run}->mark_done($cur->{job}->job_id);

    # If the whole run is complete, pop it from the queue.
    if ($cur->{run}->is_complete) {
        my $run_id = $cur->{run}->run_id;
        $self->{+QUEUE} = [grep { $_->run_id ne $run_id } @{$self->{+QUEUE}}];

        # Flip to finishing if requested (Task 15 builds on this).
        $self->{+STATE} = 'finishing'
            if $self->{+FINISH_AFTER_INITIAL_RUN}
            && $self->{+STATE} eq 'running';
    }

    delete $self->{+CURRENT};
}

sub _perform_hard_stop {
    my $self = shift;

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

    $pids{$self->{+CURRENT}{pid}} //= {} if $self->{+CURRENT};

    # Add any registered workers.
    if ($self->can('workers')) {
        $pids{$_} //= {} for keys %{$self->workers // {}};
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

    delete $self->{+CURRENT};
}

# IPC::Manager service-loop hook: a non-worker child pid was reaped.
# Handles:
#   * Collector pid tracked via $self->{+CURRENT}
#   * Preloader subprocess (restart on unexpected exit)
#   * Reparented subreaper orphans (drained elsewhere, nothing to do)
sub run_on_pid {
    my ($self, $pid, $exit) = @_;

    if (defined($self->{+PRELOADER_PID}) && $self->{+PRELOADER_PID} == $pid) {
        my $preloads = $self->{+PRELOAD} // [];
        if ($self->{+STATE} eq 'running' && @$preloads) {
            warn "$$ $0 - preloader pid $pid exited (status=$exit); restarting\n";
            delete $self->{+PRELOADER_PID};
            $self->_start_preloader;
        }
        else {
            delete $self->{+PRELOADER_PID};
        }
        return;
    }

    my $cur = $self->{+CURRENT} or return;
    return unless $cur->{pid} && $cur->{pid} == $pid;

    my $handle = $cur->{handle} or return;
    $handle->set_exit_code($exit) unless defined $handle->exit_code;

    return;
}

sub run_should_end {
    my $self = shift;

    if ($self->{+STATE} eq 'terminating') {
        return 1 if !$self->{+CURRENT};
        return 0;
    }

    if ($self->{+STATE} eq 'finishing') {
        return 1 if !$self->{+CURRENT} && !@{$self->{+QUEUE}};
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

    # Bring up the preloader subprocess if the caller asked for one.
    $self->_start_preloader if @{$self->{+PRELOAD} // []};
}

sub _start_preloader {
    my $self = shift;

    require Test2::Harness2::Preloader;

    my $config = {
        workdir     => $self->{+WORKDIR},
        name        => $self->{+PRELOADER_NAME},
        ipcm_info   => $self->ipcm_info,
        parent_pids => [$$],
        preload     => [@{$self->{+PRELOAD}}],
    };

    my $cfg_file = Test2::Harness2::Preloader->write_config_file(
        $self->{+WORKDIR},
        $config,
    );

    # The preloader inherits the *child's* @INC minus anything the
    # caller-side build_exec_argv would have picked up; that's the right
    # behavior -- the preloader process runs with the harness's view of
    # the world.
    my @argv = Test2::Harness2::Preloader->build_exec_argv(
        config_file => $cfg_file,
    );

    my $pid = fork // die "fork for preloader: $!";

    unless ($pid) {
        exec { $argv[0] } @argv
            or do {
                warn "exec preloader failed: $!\n";
                POSIX::_exit(127);
            };
    }

    $self->{+PRELOADER_PID} = $pid;
    return $pid;
}

sub run_on_cleanup {
    my $self = shift;

    # Final sweep -- any stragglers go now.
    $self->_perform_hard_stop if $self->{+CURRENT} || @{$self->{+QUEUE}};

    # Take the preloader down cleanly. shutdown is a soft stop so the
    # stage tree can teardown in order. If the preloader is unresponsive
    # we still SIGTERM and fall back to SIGKILL with a short grace period
    # rather than leaking the subprocess.
    if (my $pre_pid = delete $self->{+PRELOADER_PID}) {
        $self->_shutdown_preloader($pre_pid);
    }

    $self->_emit_service_event(kind => 'service_stopped');
}

sub _shutdown_preloader {
    my ($self, $pid) = @_;

    # Best-effort soft shutdown via IPC. Don't block forever.
    my $ok = eval {
        require IPC::Manager::Service::Handle;
        my $h = IPC::Manager::Service::Handle->new(
            service_name => $self->{+PRELOADER_NAME},
            ipcm_info    => $self->ipcm_info,
        );
        $h->sync_request($self->{+PRELOADER_NAME}, {request => 'shutdown'}) if $h->ready;
        1;
    };
    warn "preloader soft shutdown failed: $@" unless $ok;

    # Grace period for clean exit, then SIGTERM, then SIGKILL.
    my $deadline = time + 5;
    while (kill(0, $pid) && time < $deadline) {
        sleep(0.05);
        last if waitpid($pid, WNOHANG) == $pid;
    }

    if (kill 0, $pid) {
        kill TERM => $pid;
        my $kdl = time + 5;
        while (kill(0, $pid) && time < $kdl) {
            sleep(0.05);
            last if waitpid($pid, WNOHANG) == $pid;
        }
    }

    if (kill 0, $pid) {
        kill KILL => $pid;
        waitpid $pid, 0;
    }

    return;
}

sub _emit_service_event {
    my ($self, %fields) = @_;
    my $em = $self->{+EMITTER} or return;    # no emitter in tests
    $em->emit_event(%fields);
}

sub run_on_all {
    my ($self, $activity) = @_;

    # IPC::Manager's service loop already reaped any exited child and
    # routed non-worker pids through run_on_pid(), so by the time we
    # get here the collector Handle has its exit_code stashed when
    # applicable. _check_current_completion reads that via
    # $handle->is_done without needing to waitpid itself.
    $self->_check_current_completion;

    return if $self->{+CURRENT};
    return if $self->{+STATE} eq 'terminating';
    return unless @{$self->{+QUEUE}};

    my $run = $self->{+QUEUE}[0];
    return unless @{$run->pending};

    my $job_id = $run->pending->[0];
    my ($job) = grep { $_->job_id eq $job_id } @{$run->jobs};

    my $run_id  = $run->run_id;
    my $log_dir = join '/', $self->{+WORKDIR}, 'runs', $run_id, $job_id;
    make_path($log_dir);
    my $log_file = "$log_dir/0.jsonl";

    my $handle = Test2::Harness2::Collector->spawn(
        launch      => [$^X, '-Ilib', $job->test_file_abs],
        new_pgroup  => 1,
        parent_pids => [$$],
        env_vars    => {T2_FORMATTER => 'Stream2'},
        run_id      => $run_id,
        job_id      => $job_id,
        job_try     => 0,
        ipcm_info   => $self->ipcm_info,
        auditor     => $self->{+TEST_AUDITOR},
        loggers     => [
            [$self->{+TEST_LOGGERS}[0], output_file => $log_file],
            [
                'Test2::Harness2::Collector::Logger::IPCNotify',
                service_name => $self->{+NAME},
            ],
        ],
    );

    $run->mark_running($job_id);

    $self->{+CURRENT} = {
        run        => $run,
        job        => $job,
        handle     => $handle,
        pid        => $handle->{pid},
        started_at => time,
    };

    $self->register_worker("test-$job_id", $handle->{pid})
        if $self->can('register_worker');
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
