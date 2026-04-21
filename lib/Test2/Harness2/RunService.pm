package Test2::Harness2::RunService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX ();

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Role::Service;
use Test2::Harness2::Util::JSON qw/encode_json write_json_file_atomic/;

use Object::HashBase qw{
    <workdir
    <logdir
    <name
    <log_name
    <run_id
    <job_id
    <log_file
    <snapshot_file
    <kill_timeout
    <ipcm_info
    <parent_pids
    <harness_name
    <loggers
    <test_loggers
    +run
    state
    <resource_services
    +test_jobs
    +log_fh
    watch_pids
    own_pgroup
};

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj { $_[0]->{+RUN} }

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

    $self->{+LOG_NAME}          //= 'run';
    $self->{+NAME}              //= "run-$self->{+RUN_ID}";
    $self->{+HARNESS_NAME}      //= 'harness';
    $self->{+JOB_ID}            //= gen_uuid();
    $self->{+KILL_TIMEOUT}      //= 15;
    $self->{+PARENT_PIDS}       //= [];
    $self->{+STATE}             //= 'running';
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+TEST_JOBS}         //= {};
    $self->{+WATCH_PIDS}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    # log_file is the run service's own direct-JSONL audit trail;
    # distinct from the configurable `loggers` slot. The default
    # keeps the classic per-run layout under
    # $logdir/runs/<run_id>/services/<log_name>.jsonl. Set it to
    # undef explicitly to disable the audit trail.
    $self->{+LOG_FILE}      //= "$svc_dir/$self->{+LOG_NAME}.jsonl";
    $self->{+SNAPSHOT_FILE} //= "$logdir/runs/$self->{+RUN_ID}.json";

    # Logger specs. Both default to []; the caller (typically the
    # harness) supplies them at spawn time.
    $self->{+LOGGERS}      //= [];
    $self->{+TEST_LOGGERS} //= [];

    croak "'loggers' must be an arrayref"
        unless ref($self->{+LOGGERS}) eq 'ARRAY';
    croak "'test_loggers' must be an arrayref"
        unless ref($self->{+TEST_LOGGERS}) eq 'ARRAY';
}

# Atomic-swap the runs/<run_id>.json snapshot with the run's current
# TO_JSON. Called once at startup (initial state) and once at cleanup
# (final state); the atomic write means downstream readers always see a
# consistent file, never a partial one. This is what the upstream
# 'reimplement-resource-classes'-branch comments in Test2::Harness2
# referred to as "the run service's JSON logger takes over".
sub _write_snapshot {
    my $self = shift;
    write_json_file_atomic($self->{+SNAPSHOT_FILE}, $self->{+RUN}->TO_JSON);
    return;
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
    # for targeted launches (e.g. synth-skip / synth-fail). This
    # service no longer injects any hard-coded JSONL / JSON pair --
    # if the caller wants those, they include the specs (typically
    # with placeholder paths, see below).
    my $payload_loggers = $payload->{loggers} // $self->{+TEST_LOGGERS} // [];
    my $test_file_abs   = $payload->{test_file};
    my $launch_cmd      = $payload->{launch};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless $test_file_abs =~ m{^/};

    # The harness's synthetic-skip / synthetic-fail paths hand us an
    # explicit launch command (perl -e '...'). Default to running the
    # real test file when no override is present.
    $launch_cmd //= [$^X, '-Ilib', $test_file_abs];

    # Per-job log directory exists for any logger that wants to write
    # something per-try. Callers describe the path via %LOG_DIR% /
    # %JOB_TRY% placeholders in their spec; we fill them in below.
    my $log_dir = join '/', $self->{+LOGDIR}, 'runs', $run_id, $job_id;
    make_path($log_dir);

    # Default the payload-level log_file only if the caller wants one;
    # loggers are otherwise driven entirely by the payload_loggers
    # specs. Kept for back-compat with callers that pass log_file
    # explicitly.
    $log_file //= undef;

    my %ctx = (
        LOGDIR  => $self->{+LOGDIR},
        LOG_DIR => $log_dir,
        RUN_ID  => $run_id,
        JOB_ID  => $job_id,
        JOB_TRY => $job_try,
    );
    my @logger_specs = map { _expand_logger_spec($_, \%ctx) } @$payload_loggers;

    my $handle;
    my $spawn_ok = eval {
        require Test2::Harness2::Collector::Test;
        $handle = Test2::Harness2::Collector::Test->spawn(
            launch      => $launch_cmd,
            new_pgroup  => 1,
            parent_pids => [$$],
            env_vars    => {T2_FORMATTER => 'Stream2', %$env},
            run_id      => $run_id,
            job_id      => $job_id,
            job_try     => $job_try,
            ipcm_info   => $self->ipcm_info,
            ipc_parent  => $self->{+NAME},
            ipc_run     => $self->{+NAME},
            ipc_harness => $self->{+HARNESS_NAME},
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
# run-specific extras: run_id in the service_started event, the
# initial snapshot, and bringing up the run's resource services.
sub service_started_fields {
    my $self = shift;
    return (run_id => $self->{+RUN_ID});
}

sub service_on_start {
    my $self = shift;

    # Initial snapshot of the run. The final snapshot is written during
    # run_on_cleanup after the state transitions are committed.
    my $snap_ok = eval { $self->_write_snapshot; 1 };
    warn "run-service initial snapshot write failed: $@" unless $snap_ok;

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

    # Test-collector exit: tell the harness so it can release resources
    # and advance its scheduler. The run service's own tracking entry
    # is dropped here; the harness keeps a shadow entry until the
    # test_job_completed message is handled.
    if (my $job = delete $self->{+TEST_JOBS}->{$pid}) {
        $self->_send_to_harness(
            {
                kind    => 'test_job_completed',
                run_id  => $job->{run_id},
                job_id  => $job->{job_id},
                job_try => $job->{job_try},
                pid     => $pid,
                exit    => $exit,
            },
        );
        return;
    }

    # Resource-service exit (handled by the shared host role).
    # Reparented descendants that aren't one of ours silently fall
    # through.
    $self->handle_resource_service_exit($pid, $exit);

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

    # Final snapshot -- downstream readers can atomically swap from the
    # queued/running snapshot to the done/final one.
    my $snap_ok = eval { $self->_write_snapshot; 1 };
    warn "run-service final snapshot write failed: $@" unless $snap_ok;

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

    my $fh = $self->{+LOG_FH} or return;    # no log in unit tests

    my $event_id = gen_uuid();
    my $stamp    = time;
    my $event    = {
        event_id   => $event_id,
        stamp      => $stamp,
        pid        => $$,
        facet_data => {
            harness => {
                event_id => $event_id,
                stamp    => $stamp,
                job_id   => $self->{+JOB_ID},
                run_id   => $self->{+RUN_ID},
                job_try  => 0,
                %fields,
            },
        },
    };

    my $ok = eval {
        print $fh encode_json($event), "\n";
        1;
    };
    warn "run service event emit failed: $@" unless $ok;
    return;
}

# ----------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------

# Take over the current process as a run service. Unlike the harness
# service, the run service does NOT interpose a Collector around its
# own stdout / stderr -- it writes JSONL events directly to its log
# file. That keeps the process tree flat (one fork per spawn, not
# two), and means spawn()'s returned pid is the run service itself
# rather than a collector wrapping it.
#
# stdout / stderr in the run-service process inherit from the caller
# (typically the harness). Anything the run service prints there
# (perl warnings, uncaught diagnostics) lands wherever the harness's
# own stdout / stderr point. That's acceptable for now: structured
# events go to the JSONL log, and unstructured output is rare.
sub start {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};

    my $self = $class->new(%args);

    my $log_fh;
    if (defined $self->{+LOG_FILE}) {
        open($log_fh, '>>', $self->{+LOG_FILE})
            or croak "cannot open run-service log '$self->{+LOG_FILE}': $!";
        $log_fh->autoflush(1);
        $self->{+LOG_FH} = $log_fh;
    }

    # The harness signals run-service shutdown with SIGTERM. The
    # service loop checks run_should_end each tick, so flipping state
    # to 'terminating' here is enough -- run_on_cleanup cascades TERMs
    # to the tracked resource services and test collectors via
    # perform_hard_stop before the process exits.
    my $self_ref = $self;
    local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

    my $exit = $self->run;

    close($log_fh) if $log_fh;

    POSIX::_exit($exit // 0);
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

    if ($pid) {
        # Parent: just return the pid. Ready-state is signalled via
        # service_started appearing on the IPC bus, but callers that
        # don't need the signal can fire-and-forget.
        return $pid;
    }

    # Child: take over the process and run the service loop.
    $class->start(%args);
    POSIX::_exit(255);    # start() should never return
}

# Substitute %LOGDIR%, %LOG_DIR%, %RUN_ID%, %JOB_ID%, %JOB_TRY%
# placeholders in a logger spec's string args. Blessed instances and
# bare class names pass through untouched (no args to substitute).
# Only scalar args are walked -- arrayref / hashref args are left
# alone; callers with richer argument shapes are responsible for
# their own substitution.
sub _expand_logger_spec {
    my ($spec, $ctx) = @_;

    return $spec if blessed($spec);
    return $spec unless ref($spec) eq 'ARRAY';

    my @out;
    for my $item (@$spec) {
        push @out => (defined($item) && !ref($item) ? _expand_placeholders($item, $ctx) : $item);
    }
    return \@out;
}

sub _expand_placeholders {
    my ($str, $ctx) = @_;
    return $str unless defined $str && index($str, '%') >= 0;

    $str =~ s/%([A-Z_]+)%/exists $ctx->{$1} ? $ctx->{$1} : "%$1%"/ge;
    return $str;
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
