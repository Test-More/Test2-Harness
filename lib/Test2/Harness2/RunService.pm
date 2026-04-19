package Test2::Harness2::RunService;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time sleep/;
use Test2::Util::UUID qw/gen_uuid/;
use POSIX qw/WNOHANG getpgrp/;

use constant IS_WIN32            => $^O eq 'MSWin32';
use constant HAS_CHILD_SUBREAPER => eval {
    require Test2::Harness2::ChildSubReaper;
    Test2::Harness2::ChildSubReaper::have_subreaper_support() ? 1 : 0;
} || 0;

use IPC::Manager::Service::Handle;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Util::IPC qw/list_direct_children/;
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
    +run
    +state
    +resource_services
    +test_jobs
    +log_fh
    +watch_pids_ref
    +own_pgroup
};

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj { $_[0]->{+RUN} }

# Reservation check on the role uses the log file name, not the bus
# name (which is suffixed with the run_id to guarantee uniqueness
# across runs on the shared IPC bus).
sub _service_host_log_name { $_[0]->{+LOG_NAME} }

# Resource-service log files live under the harness's $logdir, not the
# bare $workdir.
sub _service_host_logdir { $_[0]->{+LOGDIR} }

use Role::Tiny::With;
with 'IPC::Manager::Role::Service', 'Test2::Harness2::Role::ResourceServiceHost';

# Role::ResourceServiceHost scope hooks: the run service is the
# run-scoped host for its Run, so its own name is reserved in per-run
# scope for this specific run. A global-scoped resource never sees this
# reservation, and other runs never collide with ours.
sub _service_host_scope { 'run' }
sub _service_host_run   { $_[0]->{+RUN} }

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
    $self->{+WATCH_PIDS_REF}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    $self->{+LOG_FILE}      //= "$svc_dir/$self->{+LOG_NAME}.jsonl";
    $self->{+SNAPSHOT_FILE} //= "$logdir/runs/$self->{+RUN_ID}.json";
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

# ----------------------------------------------------------------------
# IPC::Manager::Role::Service contract
# ----------------------------------------------------------------------

sub orig_io    { {} }
sub pid        { $_[0]->{pid} //= $$ }
sub set_pid    { $_[0]->{pid} = $_[1] }
sub watch_pids { $_[0]->{+WATCH_PIDS_REF} }

# Dispatcher mirrors Harness2's: IPC::Manager envelopes each request;
# we unwrap to find the request type and route to a handler method.
sub handle_request {
    my ($self, $req, $msg) = @_;

    my $payload = $req->{request};
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};
    return {ok => 0, error => "missing request type"} unless defined $type;

    my $handler = "request_handler_$type";
    return $self->$handler($payload) if $self->can($handler);

    return {ok => 0, error => "unknown request '$type'"};
}

sub request_handler_terminate {
    my $self = shift;
    $self->_perform_hard_stop;
    return {ok => 1};
}

# Harness-to-RunService IPC: launch a test job under this run. The
# harness has already done scheduling (applicable / available / assign);
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

    my $job_id        = $payload->{job_id};
    my $job_try       = $payload->{job_try} // 0;
    my $run_id        = $payload->{run_id}  // $self->{+RUN_ID};
    my $log_file      = $payload->{log_file};
    my $env           = $payload->{env} // {};
    my $auditor       = $payload->{auditor};
    my $loggers       = $payload->{loggers} // [];
    my $test_file_abs = $payload->{test_file};

    return {ok => 0, error => "'test_file' must be absolute"}
        unless $test_file_abs =~ m{^/};

    # Default the per-job log file to runs/<run_id>/<job_id>/<try>.jsonl
    # when the harness didn't pre-compute one. The path layout mirrors
    # the one the harness itself used to use when it still launched
    # jobs directly.
    unless (defined $log_file) {
        my $log_dir = join '/', $self->{+LOGDIR}, 'runs', $run_id, $job_id;
        make_path($log_dir);
        $log_file = "$log_dir/$job_try.jsonl";
    }

    my @logger_specs;
    push @logger_specs => @$loggers;

    my $json_file = $log_file;
    $json_file =~ s/\.jsonl$/.json/;

    my $handle;
    my $spawn_ok = eval {
        $handle = Test2::Harness2::Collector->spawn(
            launch      => [$^X, '-Ilib', $test_file_abs],
            new_pgroup  => 1,
            parent_pids => [$$],
            env_vars    => {T2_FORMATTER => 'Stream2', %$env},
            run_id      => $run_id,
            job_id      => $job_id,
            job_try     => $job_try,
            ipcm_info   => $self->ipcm_info,
            ipc_peer    => $self->{+NAME},
            (defined $auditor ? (auditor => $auditor) : ()),
            loggers => [
                (map { [@$_] } @logger_specs),    # shallow-clone to decouple from payload
                [
                    'Test2::Harness2::Collector::Logger::JSONL',
                    output_file => $log_file,
                ],
                [
                    'Test2::Harness2::Collector::Logger::JSON',
                    output_file => $json_file,
                ],
            ],
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
    # job_complete.
    return {ok => 1, pid => $pid, log_file => $log_file};
}

sub request_handler_status {
    my $self = shift;

    my @services;
    for my $svc (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        push @services => {
            pid      => $svc->{pid},
            name     => $svc->{name},
            method   => $svc->{method},
            log_path => $svc->{log_path},
            restart  => $svc->{restart},
            resource => $svc->{resource}->resource_name,
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

sub run_on_start {
    my $self = shift;

    # Take over our pgroup so signals from tests can't reach us via
    # pgroup delivery -- our children (resource services + test
    # collectors) live in this new pgroup and we signal them by pid,
    # never by pgroup.
    if (POSIX::setpgid(0, 0)) {
        $self->{+OWN_PGROUP} = 1;
    }
    else {
        warn "setpgid(0,0) failed in run_on_start: $!";
    }

    # Ask the kernel to treat us as a subreaper. Reparented descendants
    # (double-forked tests, tests that setsid + _exit their immediate
    # parent) land on us instead of escaping to PID 1 or the harness.
    # This keeps per-run bookkeeping accurate and lets _perform_hard_stop
    # reach them at shutdown.
    if (HAS_CHILD_SUBREAPER) {
        Test2::Harness2::ChildSubReaper::set_child_subreaper(1)
            or warn "set_child_subreaper failed in run_on_start: $!";
    }

    # Initial snapshot of the run. The final snapshot is written during
    # run_on_cleanup after the state transitions are committed.
    my $snap_ok = eval { $self->_write_snapshot; 1 };
    warn "run-service initial snapshot write failed: $@" unless $snap_ok;

    $self->_emit_service_event(
        kind    => 'service_started',
        pid     => $$,
        pgid    => getpgrp(),
        name    => $self->{+NAME},
        run_id  => $self->{+RUN_ID},
        workdir => $self->{+WORKDIR},
    );

    # Bring up the run's resource services. The harness is expected to
    # have already validated the resource set (applicable + non-permanent)
    # before spawning us; we just start whatever's configured.
    my $resources = $self->{+RUN}->resources // [];
    $self->_start_resource_services($resources, scope => 'run', run => $self->{+RUN})
        if @$resources;
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
    # job_complete message is handled.
    if (my $job = delete $self->{+TEST_JOBS}->{$pid}) {
        $self->_send_to_harness(
            {
                kind    => 'job_complete',
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
    $self->_handle_resource_service_exit($pid, $exit);

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
    $self->_perform_hard_stop
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

    $self->_emit_service_event(kind => 'service_stopped');
}

# ----------------------------------------------------------------------
# Shutdown
# ----------------------------------------------------------------------

sub _perform_hard_stop {
    my $self = shift;

    $self->{+STATE} = 'terminating';

    my $grace = $self->{+KILL_TIMEOUT};

    my %pids;
    for my $info (values %{$self->{+RESOURCE_SERVICES} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }
    for my $info (values %{$self->{+TEST_JOBS} // {}}) {
        $pids{$info->{pid}} //= {} if $info->{pid};
    }

    # Pick up any descendants that have reparented to us via
    # PR_SET_CHILD_SUBREAPER on first enumeration. The loop below
    # refreshes this on every iteration.
    if (HAS_CHILD_SUBREAPER) {
        $pids{$_} //= {} for list_direct_children($$);
    }

    # Drop anything that's already gone -- IPC::Manager's per-tick
    # waitpid may have reaped between the terminate request arriving
    # and this method running.
    delete $pids{$_} for grep { !kill(0, $_) } keys %pids;

    my $first_sig = IS_WIN32 ? 'INT' : 'TERM';

    while (1) {
        # Pick up descendants that have reparented to us since the
        # last iteration. Same pattern the harness uses at shutdown.
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
                    $state->{IGNORE} = 1
                        if (time - $k_ts) >= $grace;
                    $unignored-- if $state->{IGNORE};
                }
                elsif ((time - $f_ts) >= $grace) {
                    push @to_kill => $pid;
                }
            }
            else {
                push @fresh => $pid;
            }
        }

        last unless $unignored;

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

        my $reaped = 0;
        while (my $pid = waitpid(-1, WNOHANG)) {
            last if $pid < 1;
            delete $pids{$pid};
            delete $self->{+RESOURCE_SERVICES}->{$pid};
            delete $self->{+TEST_JOBS}->{$pid};
            $reaped = 1;
        }

        sleep(0.05) unless $reaped || @fresh || @to_kill;
    }

    # Anything still in %pids at this point has been IGNORE'd. Drop
    # them from the tracking hashes so run_should_end sees empty
    # maps.
    $self->{+RESOURCE_SERVICES} = {};
    $self->{+TEST_JOBS}         = {};
}

# ----------------------------------------------------------------------
# Emission helper
# ----------------------------------------------------------------------

sub _emit_service_event {
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

    open(my $log_fh, '>>', $self->{+LOG_FILE})
        or croak "cannot open run-service log '$self->{+LOG_FILE}': $!";
    $log_fh->autoflush(1);
    $self->{+LOG_FH} = $log_fh;

    # The harness signals run-service shutdown with SIGTERM. The
    # service loop checks run_should_end each tick, so flipping state
    # to 'terminating' here is enough -- run_on_cleanup cascades TERMs
    # to the tracked resource services and test collectors via
    # _perform_hard_stop before the process exits.
    my $self_ref = $self;
    local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

    my $exit = $self->run;

    close($log_fh);

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
