package App::Yath2::Renderer2::Base;
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
    +_state
    +_artifact_monitors
};

my %VALID_CRITICALITY = (best_effort => 1, required => 1);

sub init {
    my $self = shift;

    $self->{+CRITICALITY} //= 'best_effort';
    croak "invalid criticality '$self->{+CRITICALITY}': must be one of: best_effort, required"
        unless $VALID_CRITICALITY{$self->{+CRITICALITY}};

    $self->{+_STATE}             = {};
    $self->{+_ARTIFACT_MONITORS} = {};

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

App::Yath2::Renderer2::Base - Pull-model renderer base class with two-hook handlers and artifact-monitor lifecycle.

=head1 DESCRIPTION

C<App::Yath2::Renderer2::Base> is the base class for all renderers in the
C<App::Yath2::Renderer2::*> namespace. It implements a pull-model rendering
contract: the render loop (see C<App::Yath2::Renderer2::Loop>) drives
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

=head2 Transitional namespace

This class lives under C<App::Yath2::Renderer2::*> during the current
migration phase. It will be renamed to C<App::Yath2::Renderer::*> in stage
9.10 once the legacy renderer stack has been removed.

=head1 SYNOPSIS

    package My::Renderer;
    use parent 'App::Yath2::Renderer2::Base';

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
