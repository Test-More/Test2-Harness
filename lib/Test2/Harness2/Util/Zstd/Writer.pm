package Test2::Harness2::Util::Zstd::Writer;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Fcntl qw/O_WRONLY O_APPEND O_CREAT/;

use Compress::Zstd ();

# Each call to print/say emits exactly one zstd frame compressed
# from the supplied payload, then atomically appends the frame to the
# underlying file. Multiple writers can append concurrently as long as
# each frame fits in PIPE_BUF (4 KiB on Linux); the per-line jsonl
# events we produce stay well below that.

sub _open {
    my ($class, $path) = @_;

    croak "path is required" unless defined $path;

    sysopen(my $fh, $path, O_WRONLY | O_APPEND | O_CREAT, 0644)
        or croak "open '$path' for append: $!";
    binmode $fh;

    my $self = bless {
        path => $path,
        fh   => $fh,
    } => $class;

    return $self;
}

sub print {
    my $self    = shift;
    my $payload = join '', @_;
    my $frame   = Compress::Zstd::compress($payload);
    return $self->_emit_frame($frame);
}

# Compress payload + "\n" together so the resulting frame
# uncompresses to a complete jsonl line. Callers writing JSONL
# events should use this rather than ->print so the consumer can
# stitch frames together via raw concatenation without per-frame
# newline-insertion logic.
sub say {
    my $self = shift;
    return $self->print(@_, "\n");
}

# Append a fully-formed zstd frame to the file without re-compressing.
# Caller is responsible for ensuring the frame was produced with a
# matching level so the file's reader can decode it. Used by callers
# that already hold a compressed frame (e.g. the collector caches the
# on-wire frame from Atomic::Pipe and the JSONL logger writes it
# verbatim).
sub print_raw_frame {
    my $self = shift;
    my ($frame) = @_;
    croak "frame is required" unless defined $frame;
    return $self->_emit_frame($frame);
}

sub _emit_frame {
    my ($self, $frame) = @_;

    my $fh   = $self->{fh};
    my $len  = length $frame;
    my $sent = syswrite($fh, $frame);
    croak "syswrite '$self->{path}': $!"
        unless defined $sent;
    croak "short syswrite ('$self->{path}'): $sent of $len"
        if $sent != $len;

    return 1;
}

sub close {
    my $self = shift;
    my $fh   = delete $self->{fh} or return 1;
    return close($fh);
}

sub DESTROY {
    my $self = shift;
    $self->close if $self->{fh};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd::Writer - Append-safe, frame-per-record zstd writer.

=head1 SYNOPSIS

Construct via L<Test2::Harness2::Util::Zstd>'s C<open_zstd_writer>;
this class is not meant to be instantiated directly.

    use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;

    my $w = open_zstd_writer('events.jsonl.zst');
    $w->print($json_line, "\n");
    $w->close;

=head1 DESCRIPTION

Wraps an O_APPEND filehandle. Each call to L</print> compresses the
joined payload as one self-contained zstd frame and atomically
appends that frame to the file via C<syswrite>. Concurrent writers
are safe as long as a frame fits in C<PIPE_BUF> (4 KiB on Linux);
the per-line jsonl events the harness emits stay well below that.

=head1 METHODS

=over 4

=item $w->print(@list)

Compresses the concatenation of C<@list> as one zstd frame and
appends it. Returns C<1> on success, croaks on failure.

=item $w->say(@list)

Same as L</print> but appends a trailing C<"\n"> to C<@list> before
compressing.

=item $w->close

Closes the underlying file handle. Called automatically on
C<DESTROY>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::Zstd> -- helper module that constructs
this class.

L<Test2::Harness2::Util::Zstd::Reader> -- the symmetric reader.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
