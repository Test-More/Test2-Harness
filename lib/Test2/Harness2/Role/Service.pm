package Test2::Harness2::Role::Service;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/WNOHANG/;
use IO::Select ();
use Time::HiRes qw/sleep/;
use File::Spec ();
use File::Path qw/make_path/;

use Test2::Harness2::Util::Socket qw/open_unix_listen write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Role::Tiny;

requires qw/workdir name/;

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Role::Service - Common socket-service behavior: a listening
unix socket, a request/response loop, and child reaping.

=head1 DESCRIPTION

A role for the harness's long-lived services. It owns a listening unix socket
(C<< $workdir/[$run_ord/]$name.socket >>) and runs a loop that, each tick,
reaps exited children, accepts new client connections, reads framed requests and
dispatches them to C<request_handler_E<lt>typeE<gt>>, and gives the consumer a
chance to do its own work (C<service_tick>).

Requests and responses are JSON, each compressed into one self-contained zstd
frame and written with the same framing the transition channel uses, so a
L<Test2::Harness2::Util::Zstd::FrameBuffer> splits them on the read side.

A request is C<< {request =E<gt> $type, ...} >>; it dispatches to
C<request_handler_$type($payload, $conn)>, whose return value (a hashref) is sent
back as the response. A handler may return C<undef> to send B<no> response, for
one-way requests (e.g. streamed reports) whose sender does not read replies. The
built-in C<request_handler_stop> ends the loop.

=head2 Required / optional consumer methods

C<workdir> and C<name> are required. Optional: C<run_ord> (a per-run numeric
subdir), C<service_on_start> (called once after the socket binds),
C<service_tick> (called each loop iteration), C<service_on_stop> (called once
after the loop exits, before the socket is closed), and
C<service_on_reap($pid, $status)>.

=head1 PUBLIC METHODS

=cut

=over 4

=item $path = $self->service_socket_path

The listen socket path: C<< $workdir/$name.socket >>, or
C<< $workdir/$run_ord/$name.socket >> when the consumer provides a C<run_ord>.

=item $self->start_service

Open (and bind) the listening socket. Creates the socket's directory if needed.

=item $self->run

Run the service loop until stopped: reap children, service socket I/O, and call
C<service_tick>, sleeping briefly between iterations.

=item $self->stop_service

Ask the loop to exit after the current iteration.

=back

=cut

sub service_socket_path ($self) {
    my $dir = $self->workdir;
    $dir = File::Spec->catdir($dir, $self->run_ord)
        if $self->can('run_ord') && defined $self->run_ord;

    return File::Spec->catfile($dir, $self->name . '.socket');
}

sub start_service ($self) {
    my $path = $self->service_socket_path;

    my ($vol, $dir) = File::Spec->splitpath($path);
    my $sockdir = File::Spec->catpath($vol, $dir, '');
    make_path($sockdir) if length $sockdir && !-d $sockdir;

    my $listen = open_unix_listen($path);
    $listen->blocking(0);

    $self->{service_listen}  = $listen;
    $self->{service_select}  = IO::Select->new($listen);
    $self->{service_conns}   = {};
    $self->{service_stopped} = 0;

    return;
}

sub run ($self) {
    $self->start_service unless $self->{service_listen};
    $self->service_on_start if $self->can('service_on_start');

    until ($self->{service_stopped}) {
        $self->reap_children;
        $self->_service_io;
        $self->service_tick if $self->can('service_tick');
        sleep 0.01;
    }

    $self->service_on_stop if $self->can('service_on_stop');
    $self->_close_service;
    return;
}

sub stop_service ($self) {
    $self->{service_stopped} = 1;
    return;
}

=over 4

=item $self->reap_children

Reap every exited child (C<WNOHANG>), calling C<service_on_reap($pid, $status)>
for each when the consumer provides it.

=item $resp = $self->handle_request($payload, $conn)

Dispatch one decoded request to C<request_handler_$type>, returning its response
hashref (or an error hashref for a missing type / unknown handler).

=back

=cut

sub reap_children ($self) {
    my $can = $self->can('service_on_reap');
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $status = $?;
        $self->$can($pid, $status) if $can;
    }
    return;
}

sub handle_request ($self, $payload, $conn) {
    $payload = {request => $payload} unless ref($payload) eq 'HASH';

    my $type = $payload->{request};
    return {ok => 0, error => 'missing request type'} unless defined $type;

    return $self->request_handler_stop($payload, $conn) if $type eq 'stop';

    my $handler = "request_handler_$type";
    return {ok => 0, error => "unknown request '$type'"} unless $self->can($handler);

    return $self->$handler($payload, $conn);
}

=over 4

=item $resp = $self->request_handler_stop

Built-in handler: stop the loop. Returns C<< {ok =E<gt> 1} >>.

=back

=cut

sub request_handler_stop ($self, $payload = undef, $conn = undef) {
    $self->stop_service;
    return {ok => 1, stopping => 1};
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $self->_service_io

Accept pending connections, read framed requests off ready connections, dispatch
each, and write the response frame back on the same connection.

=item $self->_close_service

Close the listening socket and all connections, and unlink the socket path.

=back

=cut

sub _service_io ($self) {
    my $sel    = $self->{service_select} or return;
    my $listen = $self->{service_listen};

    while (my $conn = $listen->accept) {
        $conn->blocking(0);
        $sel->add($conn);
        $self->{service_conns}{$conn} = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    }

    for my $fh ($sel->can_read(0)) {
        next if $fh == $listen;
        my $fb = $self->{service_conns}{$fh} or next;

        my $buf = '';
        my $n   = sysread($fh, $buf, 65536);
        next unless defined $n;

        if ($n == 0) {
            $sel->remove($fh);
            delete $self->{service_conns}{$fh};
            close($fh);
            next;
        }

        $fb->push_bytes($buf);
        for my $rec ($fb->drain) {
            my $payload;
            my $ok = eval { $payload = decode_json($rec->{payload}); 1 };
            my $resp =
                  $ok
                ? $self->handle_request($payload, $fh)
                : {ok => 0, error => "undecodable request"};

            # A handler may return undef to send no response (one-way requests,
            # e.g. streamed system_load reports), so the sender's socket does
            # not accumulate unread replies.
            next unless defined $resp;

            eval { write_frame($fh, compress_blob(encode_json($resp))); 1 }
                or warn "service: failed to write response: $@\n";
        }
    }

    return;
}

sub _close_service ($self) {
    if (my $sel = $self->{service_select}) {
        for my $fh ($sel->handles) {
            $sel->remove($fh);
            close($fh);
        }
    }
    $self->{service_conns} = {};

    if (my $listen = delete $self->{service_listen}) {
        my $path = $self->service_socket_path;
        unlink $path if -e $path;
    }

    return;
}

1;

__END__

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist7@gmail.comE<gt>

=back

=head1 COPYRIGHT

Copyright Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
