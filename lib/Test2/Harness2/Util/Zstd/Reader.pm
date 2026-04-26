package Test2::Harness2::Util::Zstd::Reader;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;

use Compress::Zstd ();
use Compress::Zstd::DecompressionContext;

use Test2::Harness2::Util::Zstd ();

# A reader for a multi-frame zstd file produced by
# Test2::Harness2::Util::Zstd::Writer (or any other producer that
# emits one self-contained zstd frame per record). One frame is one
# record; readline yields the decoded payload of the next frame as
# a "line".
#
# Both the dict and no-dict paths walk raw bytes one frame at a
# time. Frame boundaries come from
# Test2::Harness2::Util::Zstd::zstd_frame_size, which parses the
# zstd frame header per RFC 8878. The records themselves are not
# required to carry inter-record newlines; producers that omit
# them and consumers that need newline-separated plaintext (the
# extract command, for instance) negotiate that separately.

sub _open {
    my ($class, $path, %opts) = @_;

    croak "path is required"    unless defined $path;
    croak "no such file: $path" unless -e $path;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;

    my $self = bless {
        path    => $path,
        fh      => $fh,
        ddict   => Test2::Harness2::Util::Zstd::_load_ddict(%opts),
        records => [],
        raw_buf => '',
        dctx    => Compress::Zstd::DecompressionContext->new,
    } => $class;

    return $self;
}

# Try to read more bytes from the underlying file handle. Returns the
# number of bytes appended to raw_buf -- 0 means "nothing right now"
# (which can be transient: a writer may append more bytes between
# this and the next call).
sub _read_more {
    my ($self) = @_;

    # Clear any sticky EOF state on the handle before each read so
    # bytes appended by another writer (or this process) since the
    # last read are visible. Idempotent: a no-op when EOF is not set.
    seek($self->{fh}, 0, 1);

    my $chunk;
    my $n = read($self->{fh}, $chunk, 65536);
    croak "read '$self->{path}': $!" unless defined $n;

    return 0 unless $n;

    $self->{raw_buf} .= $chunk;
    return $n;
}

sub _refill_records {
    my ($self) = @_;

    my $progress = $self->_read_more;

    my $dctx  = $self->{dctx};
    my $ddict = $self->{ddict};

    # Walk complete frames out of raw_buf using zstd_frame_size for
    # exact boundaries (no magic-byte scan). Each frame's decoded
    # payload becomes one record returned by readline.
    while (length $self->{raw_buf}) {
        my $size = Test2::Harness2::Util::Zstd::zstd_frame_size($self->{raw_buf});
        last unless defined $size;

        my $frame = substr($self->{raw_buf}, 0, $size);
        substr($self->{raw_buf}, 0, $size) = '';

        my $plain =
              $ddict
            ? $dctx->decompress_using_dict($frame, $ddict)
            : Compress::Zstd::decompress($frame);
        croak "zstd decompress failed in '$self->{path}'"
            unless defined $plain;

        push @{$self->{records}} => $plain;
    }

    return $progress;
}

sub readline {
    my ($self) = @_;

    while (!@{$self->{records}}) {
        my $progress = $self->_refill_records;
        last unless $progress;
    }

    return shift @{$self->{records}} if @{$self->{records}};
    return undef;
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

Test2::Harness2::Util::Zstd::Reader - Frame-oriented reader for multi-frame zstd files.

=head1 SYNOPSIS

Construct via L<Test2::Harness2::Util::Zstd>'s C<open_zstd_reader>;
this class is not meant to be instantiated directly.

    use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;

    my $r = open_zstd_reader('events.jsonl.zst', dict_path => $dict_path);
    while (defined(my $line = $r->readline)) { ... }

=head1 DESCRIPTION

Wraps a multi-frame zstd file (one self-contained frame per record,
as produced by L<Test2::Harness2::Util::Zstd::Writer>) and yields
each frame's decoded payload via L</readline>. Frames are
located using C<Test2::Harness2::Util::Zstd::zstd_frame_size>
(RFC 8878 frame-header parser); each frame is decompressed
independently. With a dict, frames go through
L<Compress::Zstd::DecompressionContext>'s C<decompress_using_dict>
with a reused context; without a dict, through
L<Compress::Zstd/decompress>.

The reader recovers from sticky-EOF state on every refill so writers
appending more bytes between reads stay visible to the next readline
call -- usable as a tail-style reader on a live append-safe file.

=head1 METHODS

=over 4

=item $record = $r->readline

Returns the decoded payload of the next zstd frame (the next
record), or C<undef> when no complete frame is available.
Producers control whether records carry trailing newlines: this
reader does not require any inter-record delimiter and does not
add or strip newlines.

=item $r->close

Closes the underlying file handle. Called automatically on
C<DESTROY>.

=back

=head1 SEE ALSO

L<Test2::Harness2::Util::Zstd> -- helper module that constructs
this class.

L<Test2::Harness2::Util::Zstd::Writer> -- the symmetric writer.

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
