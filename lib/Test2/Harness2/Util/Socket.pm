package Test2::Harness2::Util::Socket;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Errno qw/EINTR/;
use IO::Socket::UNIX ();

use Importer Importer => 'import';

our @EXPORT_OK = qw{
    open_unix_listen
    connect_unix
    write_frame
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Socket - Unix-domain socket helpers for the transition
channel.

=head1 DESCRIPTION

Thin wrappers over L<IO::Socket::UNIX> for the collector transition channel:
open a listening socket, connect to one, and write a single self-contained
frame with the blocking, C<EINTR>-safe write discipline the channel uses.
These keep socket mechanics out of the recorder and monitor.

=head1 SYNOPSIS

    use Test2::Harness2::Util::Socket qw/open_unix_listen connect_unix write_frame/;

    my $listen = open_unix_listen('/run/t.sock');   # server
    my $conn   = $listen->accept;

    my $client = connect_unix('/run/t.sock');        # collector
    write_frame($client, $zstd_frame);

=head1 EXPORTS

=cut

=over 4

=item $listen = open_unix_listen($path)

Create a C<SOCK_STREAM> C<AF_UNIX> listening socket bound to C<$path>. Unlinks
a stale path first. Croaks on failure. Returns the L<IO::Socket::UNIX> listen
handle.

=item $sock = connect_unix($path)

Connect a C<SOCK_STREAM> C<AF_UNIX> socket to C<$path>. Croaks if the socket
is not present / not accepting. Returns the connected handle.

=item write_frame($fh, $frame)

Write the bytes of C<$frame> to C<$fh> with a blocking C<syswrite>, retrying
only on C<EINTR>. Croaks on any other error or a genuine short write. Returns
C<1> on success.

=back

=cut

sub open_unix_listen ($path) {
    croak "path is required" unless defined $path && length $path;

    unlink $path if -e $path;

    my $listen = IO::Socket::UNIX->new(
        Type   => IO::Socket::UNIX::SOCK_STREAM(),
        Local  => $path,
        Listen => 1,
    ) or croak "listen on unix socket '$path': $!";

    return $listen;
}

sub connect_unix ($path) {
    croak "path is required" unless defined $path && length $path;

    my $sock = IO::Socket::UNIX->new(
        Type => IO::Socket::UNIX::SOCK_STREAM(),
        Peer => $path,
    ) or croak "connect to unix socket '$path': $!";

    return $sock;
}

sub write_frame ($fh, $frame) {
    my $len = length $frame;
    my $off = 0;

    # A reader that has gone away turns a write into SIGPIPE, which would kill
    # the writer; neutralize it locally so the failure surfaces as an EPIPE
    # error the caller can trap instead.
    local $SIG{PIPE} = 'IGNORE';

    while ($off < $len) {
        my $sent = syswrite($fh, $frame, $len - $off, $off);

        if (!defined $sent) {
            next if $! == EINTR;
            croak "syswrite to transition socket: $!";
        }

        croak "short write to transition socket: $sent bytes, $len remaining"
            if $sent == 0;

        $off += $sent;
    }

    return 1;
}

1;

__END__

=pod

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<https://github.com/Test-More/Test2-Harness>.

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
