package App::Yath2::Renderer;
use strict;
use warnings;

our $VERSION = '2.000013';

use Carp qw/croak/;

use Object::HashBase qw{
    <log
    <ipc_endpoint
    <parent_pid
    <command_pid
    <out_fh
    <criticality
    <settings
    <ipc_disabled
    +_state
    +_artifact_monitors
    +_ipc
    +_ipc_stop_seen
};

my %VALID_CRITICALITY = (best_effort => 1, required => 1);

sub init {
    my $self = shift;

    $self->{+CRITICALITY}  //= 'best_effort';
    $self->{+IPC_DISABLED} //= 0;
    croak "invalid criticality '$self->{+CRITICALITY}': must be one of: best_effort, required"
        unless $VALID_CRITICALITY{$self->{+CRITICALITY}};

    $self->{+_STATE}             = {};
    $self->{+_ARTIFACT_MONITORS} = {};
    $self->{+_IPC}               = undef;
    $self->{+_IPC_STOP_SEEN}     = 0;

    return;
}

# Two-hook handler model: one opened hook and one sealed hook per producer
# kind. Default implementations are no-ops returning undef. Subclasses
# override only the kinds they care about.
for my $kind (qw/run job service collector/) {
    no strict 'refs';
    *{"handle_${kind}_opened"} = sub { return undef };
    *{"handle_${kind}_sealed"} = sub { return undef };
}

# Artifact monitor lifecycle. The render loop calls artifact_monitors to get
# the list of active FileMonitor instances to poll on each tick, enabling
# verbose tailing of partial artifacts during live runs.

# Getters for internal slots (no public mutator; only init and the
# lifecycle methods below write to these).
sub _state             { $_[0]->{+_STATE} }
sub _artifact_monitors { $_[0]->{+_ARTIFACT_MONITORS} }

sub add_artifact_monitor {
    my ($self, $key, $monitor) = @_;
    $self->{+_ARTIFACT_MONITORS}{$key} = $monitor;
    return;
}

sub remove_artifact_monitor {
    my ($self, $key) = @_;
    delete $self->{+_ARTIFACT_MONITORS}{$key};
    return;
}

sub artifact_monitors {
    my $self = shift;
    return values %{$self->{+_ARTIFACT_MONITORS}};
}

# Returns (key, monitor) pairs for all registered artifact monitors.
# Used by the render loop to dispatch on_artifact_change with the correct key.
sub _artifact_monitor_entries {
    my $self = shift;
    return %{$self->{+_ARTIFACT_MONITORS}};
}

# connect_ipc($endpoint) — attempt to connect to the parent's IPC bus.
#
# The endpoint is a path to a JSON file containing:
#   { bus_id => '...', ipcm_info => { ... } }
#
# On success the raw IPC::Manager::Client handle is stored in _ipc. On
# failure a warning is emitted to STDERR and mark_ipc_disabled is called
# so the Loop's _check_ipc_signal short-circuits for the rest of the run
# (LIVE file watch and PID watch remain functional). Stage 8 wires the
# parent-side endpoint file creation and renderer_stop send; this method
# is the child-side contract.
sub connect_ipc {
    my ($self, $endpoint) = @_;
    return if $self->ipc_disabled;
    return if $self->{+_IPC};
    return unless defined $endpoint && length $endpoint;

    require IPC::Manager;
    require Test2::Harness2::Util::JSON;

    my $ipc;
    my $ok = eval {
        open my $fh, '<', $endpoint or die "open $endpoint: $!";
        local $/;
        my $raw = <$fh>;
        close $fh;
        my $info = Test2::Harness2::Util::JSON::decode_json($raw);
        $ipc = IPC::Manager->connect(
            $info->{bus_id},
            $info->{ipcm_info},
            listen => 0,
        );
        1;
    };
    unless ($ok) {
        my $err = $@;
        warn "Renderer cannot connect IPC at $endpoint: $err. Continuing without IPC (LIVE file + PID watch remain active).\n";
        $self->mark_ipc_disabled;
        return;
    }
    $self->{+_IPC} = $ipc;
    return;
}

# ipc_stop_signaled() — non-blocking poll for a renderer_stop IPC message.
#
# Once true the result is sticky: subsequent calls return 1 without
# hitting the bus again. Returns 0 when no stop signal has been observed
# yet. Called by Loop::_check_ipc_signal each iteration.
#
# The parent sends a message of kind 'renderer_stop' to signal that the
# renderer should finish its drain pass and exit. No payload is required.
# Parent-side send wires up in stage 8.
sub ipc_stop_signaled {
    my $self = shift;
    return 1 if $self->{+_IPC_STOP_SEEN};
    return 0 unless $self->{+_IPC};

    my $ok = eval {
        for my $msg ($self->{+_IPC}->get_messages) {
            my $c = $msg->content;
            next unless ref($c) eq 'HASH';
            if (($c->{kind} // '') eq 'renderer_stop') {
                $self->{+_IPC_STOP_SEEN} = 1;
                last;
            }
        }
        1;
    };
    warn "Renderer IPC poll error: $@" unless $ok;

    return $self->{+_IPC_STOP_SEEN};
}

# _has_ipc() — return 1 when an IPC client is connected, 0 otherwise.
# Used by Loop::_check_ipc_signal to skip the poll when not connected.
sub _has_ipc { defined $_[0]->{+_IPC} ? 1 : 0 }

# mark_ipc_disabled() — set ipc_disabled to 1.
# Called at startup when the renderer cannot reach its IPC endpoint.
# Once set, the render loop's _check_ipc_signal short-circuits to 0
# so no IPC bus access is attempted for the rest of the run.
sub mark_ipc_disabled {
    my $self = shift;
    $self->{+IPC_DISABLED} = 1;
    return;
}

# on_artifact_change($key, $monitor) — called by the render loop when one
# of the renderer's registered artifact monitors reports a change.
# $key     — the key the subclass passed to add_artifact_monitor.
# $monitor — the FileMonitor instance; the subclass can call methods on it
#             to fetch new bytes or advance its own reader state.
# Default: no-op. Subclasses that want per-artifact wake-up delivery override.
sub on_artifact_change { return }

# Lifecycle hooks called by the render loop at entry and exit (including
# drain). Default implementations are no-ops; subclasses override when
# setup/teardown is needed.
sub start  { return }
sub finish { return }

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer - Pull-model renderer base class with two-hook handlers and artifact-monitor lifecycle.

=head1 DESCRIPTION

C<App::Yath2::Renderer> is the base class for all renderers in the
C<App::Yath2::Renderer::*> namespace. It implements a pull-model rendering
contract: the render loop (see C<App::Yath2::Renderer::Loop>) drives
iteration and calls hook methods on the renderer as producers are discovered
and sealed. Subclasses do not construct iterators themselves; they receive
producer objects via the hooks and consume artifact data through the log
backend.

=head2 Two-hook contract

For each producer kind (C<run>, C<job>, C<service>, C<collector>), two
hooks are defined:

=over 4

=item C<handle_<kind>_opened($producer)>

Called when the loop first sees the producer in the opened state. Default
is a no-op returning C<undef>. Subclasses override to set up per-producer
state or start tailing artifacts.

=item C<handle_<kind>_sealed($producer)>

Called when the loop observes the producer has reached the sealed state.
Default is a no-op returning C<undef>. Subclasses override to emit final
output, flush buffers, or write completed artifacts.

=back

Subclasses need only override the hooks for the kinds they care about.

=head2 Artifact-monitor lifecycle

For verbose live tailing, a renderer can register L<FileMonitor> instances
keyed by an arbitrary string. The render loop polls C<artifact_monitors> on
each tick and delivers new bytes to the monitor's callback. Monitors are
removed when the artifact is sealed or the renderer no longer needs them.

=over 4

=item C<add_artifact_monitor($key, $monitor)>

Store C<$monitor> under C<$key>.

=item C<remove_artifact_monitor($key)>

Remove the monitor stored under C<$key>.

=item C<artifact_monitors>

Return the list of currently registered monitor instances (for the loop to
poll).

=back

=head2 Criticality

The C<criticality> attribute controls how the harness handles a renderer
failure:

=over 4

=item C<best_effort> (default)

The renderer is advisory; its failure is logged but does not abort the run.
Suitable for display renderers (terminal output, progress bars).

=item C<required>

The renderer must succeed; failure is fatal to the run. Use this for
file-producing renderers (such as a future JUnit XML writer) where missing
output is an error rather than an inconvenience.

=back

=head1 SYNOPSIS

    package My::Renderer;
    use parent 'App::Yath2::Renderer';

    sub handle_job_sealed {
        my ($self, $producer) = @_;
        my $pass = $producer->pass ? 'ok' : 'not ok';
        printf {$self->out_fh} "%s  %s\n", $pass, $producer->id;
        return;
    }

    1;

=head1 ATTRIBUTES

All attributes are read-only after construction.

=over 4

=item $log = $r->log

The L<App::Yath2::Role::Log> backend instance. May be C<undef> for
renderers that do not read artifact data directly.

=item $endpoint = $r->ipc_endpoint

String endpoint of the parent's IPC bus. The renderer may connect back to
receive an out-of-band shutdown signal. May be C<undef>.

=item $pid = $r->parent_pid

PID of the parent (collector) process. Used for liveness checks.

=item $pid = $r->command_pid

PID of the command process. Used for liveness checks.

=item $fh = $r->out_fh

Output filehandle. Renderers write display output here.

=item $str = $r->criticality

Either C<'best_effort'> (default) or C<'required'>. See L</Criticality>.

=item $href = $r->settings

Hashref of arbitrary renderer-specific settings passed at construction.

=item $bool = $r->ipc_disabled

True (1) when the renderer has disabled IPC polling, false (0) otherwise.
Defaults to 0 at construction. Set via C<mark_ipc_disabled>.

=back

=head1 METHODS

=over 4

=item $r->start

Called once by the render loop before entering the poll cycle. Default
no-op; override to perform setup.

=item $r->finish

Called once by the render loop after the poll cycle ends (including drain).
Default no-op; override to perform teardown and flush.

=item $r->handle_run_opened($producer)

=item $r->handle_run_sealed($producer)

=item $r->handle_job_opened($producer)

=item $r->handle_job_sealed($producer)

=item $r->handle_service_opened($producer)

=item $r->handle_service_sealed($producer)

=item $r->handle_collector_opened($producer)

=item $r->handle_collector_sealed($producer)

Hook methods called by the render loop as producers transition through
states. All default to no-ops returning C<undef>.

=item $r->add_artifact_monitor($key, $monitor)

=item $r->remove_artifact_monitor($key)

=item @monitors = $r->artifact_monitors

Artifact-monitor lifecycle methods. See L</Artifact-monitor lifecycle>.

=item $r->on_artifact_change($key, $monitor)

Called by the render loop when the artifact monitor registered under C<$key>
reports a change. C<$monitor> is the L<Test2::Harness2::Util::FileMonitor>
instance; the subclass can call C<< $monitor->changed >> (already consumed by
the loop) or advance its own reader state based on the wake-up. Default is a
no-op. Subclasses that perform verbose artifact tailing override this.

=item $r->connect_ipc($endpoint)

Attempt to connect to the parent's IPC bus. C<$endpoint> must be the path
to a JSON file containing C<{ bus_id =E<gt> '...', ipcm_info =E<gt> {...} }>.

On success the IPC client handle is stored internally and
C<ipc_stop_signaled> becomes active. On failure a warning is emitted to
STDERR and C<mark_ipc_disabled> is called so the render loop's IPC check
short-circuits for the rest of the run (LIVE file watch and PID watch
remain functional).

The parent writes this endpoint file and sends the C<renderer_stop> message
when the C<yath render> command exists as a real command (stage 8). This
method is the child-side contract.

=item $bool = $r->ipc_stop_signaled

Non-blocking poll of the IPC bus for a C<renderer_stop> message. Returns 1
when such a message has been observed, 0 otherwise. The result is sticky:
once true, subsequent calls return 1 without hitting the bus again.

The parent sends an IPC message with C<< { kind => 'renderer_stop' } >> to
instruct the renderer to finish its drain pass and exit.

=item $bool = $r->_has_ipc

Returns 1 when an IPC client is connected, 0 otherwise. Used by the render
loop to skip the poll when no connection has been established.

=item $r->mark_ipc_disabled

Set the C<ipc_disabled> flag to 1. Call this at startup when the renderer
cannot reach its IPC endpoint. After this call the render loop's IPC check
short-circuits to 0 for the rest of the run.

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

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
