package Test2::Harness2::Util::Zstd::FrameBuffer;
use v5.38;

our $VERSION = '2.000000';

use Carp qw/croak/;
use Compress::Zstd ();

use Test2::Harness2::Util::Zstd qw/zstd_frame_size/;

use Object::HashBase qw{
    <buf
};

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd::FrameBuffer - Accumulate bytes and yield complete
decoded zstd frames.

=head1 DESCRIPTION

A small byte accumulator for the "one self-contained zstd frame per record"
wire shape. Feed it raw bytes as they arrive (from a file, a socket, a pipe)
with L</push_bytes>; pull complete frames back out with L</next_frame> or
L</drain>. Each returned frame is a hashref with the raw on-wire C<frame>
bytes (so a forwarder can re-send verbatim, without recompressing) and the
decoded C<payload>. Incomplete trailing bytes stay buffered until the rest of
the frame arrives.

Frame boundaries are located with
L<Test2::Harness2::Util::Zstd/zstd_frame_size> (an RFC 8878 frame-header
parser), so no scanning for magic and no false split on a partial write.

=head1 SYNOPSIS

    my $b = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    $b->push_bytes($bytes_from_socket);
    while (my $rec = $b->next_frame) {
        do_something($rec->{payload});      # decoded
        forward_verbatim($rec->{frame});    # raw on-wire bytes
    }

=head1 ATTRIBUTES

=over 4

=item buf

Internal raw-byte accumulator. Not part of the public interface.

=back

=cut

sub init ($self) {
    $self->{+BUF} //= '';
    return;
}

=head1 PUBLIC METHODS

=cut

=over 4

=item push_bytes

=item $b->push_bytes($bytes)

Append raw bytes to the internal buffer. Returns nothing.

=item next_frame

=item $rec = $b->next_frame

Return the next complete frame as C<< { frame => $raw, payload => $decoded } >>,
removing it from the buffer, or C<undef> when the buffer does not yet hold a
complete frame. Croaks if a complete frame fails to decompress.

=item drain

=item @recs = $b->drain

Return every complete frame currently in the buffer (each as the hashref
L</next_frame> yields), in order, leaving only an incomplete trailing frame
buffered.

=back

=cut

sub push_bytes ($self, $bytes) {
    return unless defined $bytes && length $bytes;
    $self->{+BUF} .= $bytes;
    return;
}

sub next_frame ($self) {
    my $size = zstd_frame_size($self->{+BUF});
    return undef unless defined $size;

    my $frame = substr($self->{+BUF}, 0, $size, '');

    my $payload = Compress::Zstd::decompress($frame);
    croak "zstd decompress failed on a complete frame"
        unless defined $payload;

    return {frame => $frame, payload => $payload};
}

sub drain ($self) {
    my @out;
    while (defined(my $rec = $self->next_frame)) {
        push @out => $rec;
    }
    return @out;
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
