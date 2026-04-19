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

use constant IS_WIN32 => $^O eq 'MSWin32';

use Atomic::Pipe;
use Test2::Harness2::Collector;
use Test2::Harness2::Role::ResourceServiceHost;
use Test2::Harness2::Util::EventEmitter;

use Object::HashBase qw{
    <workdir
    <name
    <run_id
    <job_id
    <loggers
    <kill_timeout
    <ipcm_info
    <parent_pids
    <jump_to
    +run
    +state
    +resource_services
    +emitter
    +watch_pids_ref
    +own_pgroup
};

# Public accessor for the Run object -- named run_obj rather than 'run'
# to avoid shadowing IPC::Manager::Role::Service's run() loop method.
sub run_obj { $_[0]->{+RUN} }

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

    my $svc_dir = "$wd/runs/$self->{+RUN_ID}/services";
    make_path($svc_dir) unless -d $svc_dir;

    $self->{+NAME}              //= 'run';
    $self->{+JOB_ID}            //= gen_uuid();
    $self->{+KILL_TIMEOUT}      //= 15;
    $self->{+PARENT_PIDS}       //= [];
    $self->{+STATE}             //= 'running';
    $self->{+RESOURCE_SERVICES} //= {};
    $self->{+WATCH_PIDS_REF}    //= [@{$self->{+PARENT_PIDS}}];
    $self->{+OWN_PGROUP}        //= 0;

    $self->{+LOGGERS} //= [
        [
            'Test2::Harness2::Collector::Logger::JSONL',
            output_file => "$svc_dir/$self->{+NAME}.jsonl",
        ],
    ];
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

    return {
        service => {
            name    => $self->{+NAME},
            pid     => $$,
            job_id  => $self->{+JOB_ID},
            workdir => $self->{+WORKDIR},
            run_id  => $self->{+RUN_ID},
            state   => $self->{+STATE},
        },
        resource_services => \@services,
    };
}

sub run_on_start {
    my $self = shift;

    # Take over our pgroup so signals from tests can't reach us via
    # pgroup delivery -- our children (resource services) live in this
    # new pgroup and we signal them by pid, never by pgroup.
    if (POSIX::setpgid(0, 0)) {
        $self->{+OWN_PGROUP} = 1;
    }
    else {
        warn "setpgid(0,0) failed in run_on_start: $!";
    }

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

    # Only resource services live under us. Anything else is either a
    # reparented grandchild or a stranger -- _handle_resource_service_exit
    # returns 0 for non-ours and we drop it on the floor.
    $self->_handle_resource_service_exit($pid, $exit);

    return;
}

sub run_should_end {
    my $self = shift;

    return 0 unless $self->{+STATE} eq 'terminating';

    # Wait until every resource service we were tracking has exited
    # before we let the loop unwind.
    return 0 if keys %{$self->{+RESOURCE_SERVICES} // {}};
    return 1;
}

sub run_on_cleanup {
    my $self = shift;

    # Final hard-stop in case we're unwinding without a prior terminate
    # (e.g. our parent died). Drain any remaining resource services.
    $self->_perform_hard_stop if keys %{$self->{+RESOURCE_SERVICES} // {}};

    for my $res (@{$self->{+RUN}->resources // []}) {
        my $ok  = eval { $res->teardown; 1 };
        my $err = $@;
        warn "resource '" . $res->resource_name . "' teardown died: $err"
            unless $ok;
    }

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

    # Drop anything that's already gone -- IPC::Manager's per-tick
    # waitpid may have reaped between the terminate request arriving
    # and this method running.
    delete $pids{$_} for grep { !kill(0, $_) } keys %pids;

    my $first_sig = IS_WIN32 ? 'INT' : 'TERM';

    while (1) {
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
            $reaped = 1;
        }

        sleep(0.05) unless $reaped || @fresh || @to_kill;
    }

    # Anything still in %pids at this point has been IGNORE'd. Drop
    # them from the tracking hash so run_should_end sees an empty
    # services map.
    $self->{+RESOURCE_SERVICES} = {};
}

# ----------------------------------------------------------------------
# Emission helper
# ----------------------------------------------------------------------

sub _emit_service_event {
    my ($self, %fields) = @_;
    my $em = $self->{+EMITTER} or return;    # no emitter in tests
    $em->emit_event(%fields);
}

# ----------------------------------------------------------------------
# Entry points
# ----------------------------------------------------------------------

# Take over the current process as a run service. Mirrors
# Test2::Harness2::start(): interposes the Collector so stdout/stderr
# are piped through the configured loggers, then runs the IPC::Manager
# service loop. Does not return.
sub start {
    my ($class, %args) = @_;

    croak "'ipcm_info' is required" unless defined $args{ipcm_info};

    my $self = $class->new(%args);

    my $loggers = $self->{+LOGGERS};

    my $run_service = sub {
        my $stdout_apipe = Atomic::Pipe->from_fh('>&=', \*STDOUT);
        $stdout_apipe->set_mixed_data_mode();
        $self->{+EMITTER} = Test2::Harness2::Util::EventEmitter->new(
            pipe   => $stdout_apipe,
            job_id => $self->job_id,
        );

        # The harness signals run-service shutdown with SIGTERM. The
        # service loop checks run_should_end each tick, so flipping
        # state to 'terminating' here is enough -- run_on_cleanup
        # will then cascade TERMs to the tracked resource services
        # via _perform_hard_stop before the process exits.
        my $self_ref = $self;
        local $SIG{TERM} = sub { $self_ref->{+STATE} = 'terminating' };

        my $exit = $self->run;
        POSIX::_exit($exit // 0);
    };

    my $jump_to = $self->{+JUMP_TO};

    Test2::Harness2::Collector->interpose(
        ipcm_info   => $self->ipcm_info,
        loggers     => $loggers,
        parser      => 'Test2::Harness2::Collector::Parser::IOParser',
        parent_pids => $self->{+PARENT_PIDS},
        (defined($jump_to) ? (jump_to => $jump_to, jump_payload => $run_service) : ()),
    );

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
