package Test2::Harness2;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use File::Spec ();
use File::Path qw/make_path/;
use POSIX ();
use Time::HiRes qw/sleep time/;

use Test2::Util::UUID qw/gen_uuid/;

use Test2::Harness2::Util::Socket qw/connect_unix write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;
use Test2::Harness2::Collector::Monitor;

use Object::HashBase qw{
    <project
    <workdir
    <service_class
    <service_name
    <service_pid
    <service_events_file
    <sub_sock
    <sub_buffer
    <monitor
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2 - Client API to start and/or connect to a harness service.

=head1 DESCRIPTION

The entry point for driving a harness: it owns (or vivifies) a workdir, knows
which service class to run, and can start a service in a child process and/or
connect to a running one to queue runs and observe their progress.

The harness service itself is L<Test2::Harness2::Service::Harness> (overridable);
it runs its own socket loop. See L<Test2::Harness2::Role::Service>.

=head1 SYNOPSIS

    my $t2h2 = Test2::Harness2->new(project => 'myapp');
    $t2h2->start;                                  # fork + run the service
    my $run = $t2h2->queue_run(files => \@tests);  # returns {run_uuid, run_ord}
    ...

    # Or connect to an already-running service:
    my $t2h2 = Test2::Harness2->connect(project => 'myapp', workdir => $dir);

=head1 ATTRIBUTES

=over 4

=item project (required)

A short project identifier. Required -- no guessing or default. Used to name the
default workdir.

=item workdir

The harness working directory. Vivified when omitted to a per-user, per-project
directory under the system temp dir (C<$TMPDIR/t2h2-$USER-$PROJECT>). Created if
it does not exist.

=item service_class

The harness service class to run. Defaults to
L<Test2::Harness2::Service::Harness>.

=item service_name

The global service name (and socket basename). Defaults to C<harness>.

=back

=cut

sub init ($self) {
    croak "'project' is a required attribute"
        unless defined $self->{+PROJECT} && length $self->{+PROJECT};

    $self->{+SERVICE_CLASS} //= 'Test2::Harness2::Service::Harness';
    $self->{+SERVICE_NAME}  //= 'harness';
    $self->{+WORKDIR}       //= $self->_default_workdir;

    make_path($self->{+WORKDIR}) unless -d $self->{+WORKDIR};

    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item $t2h2 = Test2::Harness2->connect(project => ..., workdir => ...)

Construct a harness API object bound to an existing workdir/service without
starting a new service. (Currently an alias for C<new>; the caller then uses the
client connection.)

=item $path = $t2h2->socket_path

The unix socket path the service listens on: C<< $workdir/$service_name.socket >>.

=back

=cut

sub connect ($class, %args) {
    return $class->new(%args);
}

sub socket_path ($self) {
    return File::Spec->catfile($self->{+WORKDIR}, "$self->{+SERVICE_NAME}.socket");
}

=over 4

=item $t2h2->start

Fork the harness service into a child process and wait for it to bind its
socket. The service runs L<Test2::Harness2::Service::Harness> (or the configured
C<service_class>).

=item $resp = $t2h2->queue_run(files => \@files, run_uuid => ..., stray => 0|1)

Queue a run. Returns the service response C<< {ok, run_uuid, run_ord, job_uuids} >>.

=item $t2h2->no_more_runs

Tell the service no further runs will be queued, so it shuts down once the
current work finishes.

=item $mon = $t2h2->subscribe

Open a streaming connection and register it with the service so collector state
updates are forwarded to us; returns the L<Test2::Harness2::Collector::Monitor>
(unmanaged) that L</poll_state> folds those updates into.

=item poll_state

=item $mon = $t2h2->poll_state

Read any pending state frames off the subscribe connection into the monitor, and
return the monitor for querying (C<new_test_exits>, C<final_state>, ...).

=item $t2h2->shutdown

Ask the service to stop and reap its process.

=back

=cut

sub start ($self) {
    require Test2::Harness2::Collector;
    require Test2::Harness2::Collector::Recorder;

    my $class = $self->{+SERVICE_CLASS};
    eval "require $class; 1" or croak $@;

    my $wd     = $self->{+WORKDIR};
    my $name   = $self->{+SERVICE_NAME};
    my $events = File::Spec->catfile($wd, "$name.jsonl.zst");
    $self->{+SERVICE_EVENTS_FILE} = $events;

    # Every service runs under a collector so its output is captured to the
    # service events file. The collector forks the service, which binds the
    # request socket and runs its loop.
    my $pid = Test2::Harness2::Collector::spawn_collector(
        is_test  => 0,
        name     => $name,
        uuid     => gen_uuid(),
        run      => sub { $class->new(workdir => $wd, name => $name)->run },
        recorder => Test2::Harness2::Collector::Recorder->new(events_file => $events),
    );

    $self->{+SERVICE_PID} = $pid;

    my $path     = $self->socket_path;
    my $deadline = time + 30;
    sleep 0.01 until -S $path || time > $deadline;
    croak "harness service did not start (no socket at $path)" unless -S $path;

    return $self;
}

sub queue_run ($self, %args) {
    return $self->_request({request => 'queue_run', %args});
}

sub no_more_runs ($self) {
    return $self->_request({request => 'no_more_runs'});
}

sub subscribe ($self) {
    my $sock = connect_unix($self->socket_path);
    write_frame($sock, compress_blob(encode_json({request => 'subscribe'})));

    my $fb = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    $self->_read_one_frame($sock, $fb);    # consume the subscribe response

    $sock->blocking(0);
    $self->{+SUB_SOCK}   = $sock;
    $self->{+SUB_BUFFER} = $fb;
    $self->{+MONITOR}    = Test2::Harness2::Collector::Monitor->new;    # unmanaged

    return $self->{+MONITOR};
}

sub poll_state ($self) {
    my $sock = $self->{+SUB_SOCK} or return $self->{+MONITOR};
    my $fb   = $self->{+SUB_BUFFER};

    while (1) {
        my $buf = '';
        my $n   = sysread($sock, $buf, 65536);
        last unless $n;    # undef (would-block) or 0 (EOF)
        $fb->push_bytes($buf);
    }

    for my $rec ($fb->drain) {
        $self->{+MONITOR}->feed_frame($rec->{frame});
    }

    $self->{+MONITOR}->sweep;

    return $self->{+MONITOR};
}

sub shutdown ($self) {
    eval { $self->_request({request => 'stop'}); 1 };
    if (my $pid = $self->{+SERVICE_PID}) {
        waitpid($pid, 0);
    }
    return;
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $resp = $self->_request($payload)

Open a fresh connection to the service, send one framed request, read and return
the decoded response.

=item $payload = $self->_read_one_frame($sock, $fb)

Block until one complete frame is read off C<$sock> (accumulating in C<$fb>) and
return its decoded payload.

=back

=cut

sub _request ($self, $payload) {
    my $sock = connect_unix($self->socket_path);
    write_frame($sock, compress_blob(encode_json($payload)));
    my $fb = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    return $self->_read_one_frame($sock, $fb);
}

sub _read_one_frame ($self, $sock, $fb) {
    my $deadline = time + 30;
    while (time < $deadline) {
        my $buf = '';
        my $n   = sysread($sock, $buf, 65536);

        # 0 (EOF) or undef (error) on this blocking socket means the service
        # closed the connection without a (complete) response -- e.g. it shut
        # down while we were asking. Do not busy-wait to the deadline.
        croak "harness service closed the connection without responding" unless $n;

        $fb->push_bytes($buf);
        for my $rec ($fb->drain) {
            return decode_json($rec->{payload});
        }
    }
    croak "no response from harness service within timeout";
}

=head1 PRIVATE METHODS

=cut

=over 4

=item $dir = $self->_default_workdir

The vivified default workdir: C<$TMPDIR/t2h2-$USER-$PROJECT>.

=back

=cut

sub _default_workdir ($self) {
    my $user = $ENV{USER} // $ENV{LOGNAME} // 'user';
    return File::Spec->catdir(File::Spec->tmpdir, "t2h2-$user-$self->{+PROJECT}");
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
