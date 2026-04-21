package Test2::Harness2::Spawn;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;

use Object::HashBase qw{
    <pid
    <ipcm_info
    <workdir
    <name
    +handle
    <terminate_on_destroy
};

sub init {
    my $self = shift;
    croak "'pid' is required"       unless defined $self->{+PID};
    croak "'ipcm_info' is required" unless defined $self->{+IPCM_INFO};
    croak "'workdir' is required"   unless defined $self->{+WORKDIR};
    $self->{+NAME}                 //= 'harness';
    $self->{+TERMINATE_ON_DESTROY} //= 1;
}

sub handle {
    my $self = shift;
    $self->{+HANDLE} //= $self->_build_handle;
}

sub _build_handle {
    my $self = shift;
    require IPC::Manager::Service::Handle;
    return IPC::Manager::Service::Handle->new(
        service_name => $self->{+NAME},
        ipcm_info    => $self->{+IPCM_INFO},
    );
}

# Sends a synchronous request to the service and returns the response content.
# IPC::Manager's sync_request($peer, $payload) sends:
#   { ipcm_request_id => ..., request => $payload }
# to the service.  The service's handle_request receives that whole envelope
# as $req and dispatches on $req->{request}, which here is a hashref
# containing the 'request' dispatch key plus any extra fields.
# We extract and return only the inner 'response' value from the envelope.
sub _send_request {
    my ($self, $name, $payload) = @_;
    $payload //= {};
    my $hdl  = $self->handle;
    my $resp = $hdl->sync_request($self->{+NAME}, {request => $name, %$payload});
    return $resp->{response};
}

sub queue_test_run {
    my $self = shift;
    my %args =
          @_ == 1 && ref($_[0]) eq 'HASH' ? %{$_[0]}
        : @_ % 2 == 0                     ? @_
        :                                   (files => [@_]);
    return $self->_send_request('queue_test_run', \%args);
}

sub status { $_[0]->_send_request('status') }
sub finish { $_[0]->_send_request('finish') }

# Per-run status query. Returns the service's snapshot of a single run
# (identified by run_id), whether it is still executing or already
# completed. Callers (yath test, yath run) use this to poll for
# drain + read the per-run tally, rather than reaching into the
# harness-wide status response.
sub run_status {
    my ($self, $run_id) = @_;
    croak "'run_id' is required" unless defined $run_id && length $run_id;
    return $self->_send_request('run_status', {run_id => $run_id});
}

# Artifact enumeration for the command-side artifact-reading layer.
# See IPC_AND_LOGGERS §13.1. Each returns a {ok, artifacts} response
# whose artifacts key is a { collector_id => { loggers, ... } } hash.
sub list_global_artifacts {
    my $self = shift;
    return $self->_send_request('list_global_artifacts');
}

sub list_run_artifacts {
    my ($self, $run_id) = @_;
    croak "'run_id' is required" unless defined $run_id && length $run_id;
    return $self->_send_request('list_run_artifacts', {run_id => $run_id});
}

sub get_run_status {
    my ($self, $run_id) = @_;
    croak "'run_id' is required" unless defined $run_id && length $run_id;
    return $self->_send_request('get_run_status', {run_id => $run_id});
}

# Attached-command helpers (see IPC_AND_LOGGERS §11.2 and the Stage 14
# daemon commands). Each is a thin wrapper over _send_request so the
# command code stays declarative.
sub get_workdir     { $_[0]->_send_request('get_workdir') }
sub list_processes  { $_[0]->_send_request('list_processes') }
sub list_resources  { $_[0]->_send_request('list_resources') }
sub reload_preloads { $_[0]->_send_request('reload_preloads') }

sub abort_runs {
    my ($self, %args) = @_;
    my %payload;
    $payload{run_id} = $args{run_id} if defined $args{run_id};
    return $self->_send_request('abort_runs', \%payload);
}

sub ping { $_[0]->_send_request('ping') }

sub terminate {
    my $self = shift;
    my $res  = $self->_send_request('terminate');
    $self->wait;
    return $res;
}

sub detach {
    my $self = shift;
    my $res  = $self->_send_request('detach', {pid => $$});
    $self->{+TERMINATE_ON_DESTROY} = 0;
    return $res;
}

sub wait {
    my $self = shift;
    return if $self->{_waited};
    waitpid($self->{+PID}, 0);
    $self->{_waited} = 1;
}

sub DESTROY {
    my $self = shift;
    return unless $self->{+TERMINATE_ON_DESTROY};
    return unless kill 0, $self->{+PID};
    my $ok = eval { $self->terminate; 1 };
    warn "Spawn DESTROY terminate failed: $@" unless $ok;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Spawn - Parent-side handle returned by C<< Test2::Harness2->spawn() >>

=head1 SYNOPSIS

    my $spawn = Test2::Harness2->spawn(workdir => '/tmp/run', ...);

    # Queue a test run
    my $res = $spawn->queue_test_run('t/foo.t', 't/bar.t');
    # or
    my $res = $spawn->queue_test_run(files => ['t/foo.t'], run_id => $id);

    # Poll the service state
    my $status = $spawn->status;

    # Ask the service to drain then exit
    $spawn->finish;

    # Detach: service keeps running after this process exits
    $spawn->detach;

    # Hard-stop the service now
    $spawn->terminate;

=head1 DESCRIPTION

C<Test2::Harness2::Spawn> is the object you receive when you call
C<< Test2::Harness2->spawn(...) >>.  It wraps an
L<IPC::Manager::Service::Handle> connection to the running harness service and
exposes convenience methods that proxy the service's request handlers.

=head2 Terminate-on-destroy contract

By default, when a C<Spawn> object goes out of scope the service is
terminated automatically via C<terminate()>, which sends a C<terminate>
request and then C<waitpid()>s the daemon.  This prevents leaked background
processes when the caller forgets to clean up.

Call C<detach()> to opt out: it sends a C<detach> request (removing the
caller's PID from the service's watch-list) and clears the
C<terminate_on_destroy> flag so DESTROY becomes a no-op.

=head1 ATTRIBUTES

=over 4

=item pid

PID of the spawned service process (read-only).

=item ipcm_info

The IPC::Manager connection info returned at spawn time (read-only).

=item workdir

Working directory used by the service (read-only).

=item name

Service name (default: C<'harness'>).

=item terminate_on_destroy

Boolean; 1 by default.  Set to 0 by C<detach()>.

=back

=head1 METHODS

=over 4

=item $res = $spawn->queue_test_run(@files)

=item $res = $spawn->queue_test_run(\%args)

=item $res = $spawn->queue_test_run(%args)

Queue a test run.  C<files> key is required.

=item $status = $spawn->status

Return the current service status hashref.

=item $res = $spawn->finish

Ask the service to finish after its current queue drains.

=item $res = $spawn->terminate

Send a hard-stop C<Terminate> request and wait for the service to exit.

=item $res = $spawn->detach

Remove the caller from the service's watch-list and clear
C<terminate_on_destroy>.  The service continues running after the caller exits.

=item $spawn->wait

C<waitpid()> the service process.  Safe to call multiple times.

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

See L<https://dev.perl.org/licenses/>

=cut
