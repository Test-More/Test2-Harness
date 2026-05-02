package Test2::Harness2::Util::Zstd;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Spec ();
use File::Temp qw/tempfile/;
use Importer Importer => 'import';

use Compress::Zstd ();
use Compress::Zstd::DecompressionContext;

our @EXPORT_OK = qw{
    compress_blob
    decompress_blob
    open_zstd_writer
    open_zstd_reader
    compress_file_atomic
    decompress_file
    zstd_frame_size
    ZSTD_FRAME_MAGIC
};

# Little-endian magic bytes that mark the start of a zstd frame.
use constant ZSTD_FRAME_MAGIC => "\x28\xB5\x2F\xFD";

# ---------------------------------------------------------------------------
# One-shot helpers. Both compression and decompression run at the
# Compress::Zstd library default (level 3) -- the dictionary path was
# benchmarked at < 35% improvement over dict-less on a representative
# event-log corpus and dropped, so these helpers no longer accept any
# dict_* options.

sub compress_blob {
    my ($bytes) = @_;
    return Compress::Zstd::compress($bytes);
}

sub decompress_blob {
    my ($bytes) = @_;
    my $out = Compress::Zstd::decompress($bytes);
    croak "Compress::Zstd::decompress failed" unless defined $out;
    return $out;
}

# ---------------------------------------------------------------------------
# File-level helpers.

sub compress_file_atomic {
    my ($path, $bytes) = @_;

    croak "path is required"  unless defined $path;
    croak "bytes is required" unless defined $bytes;

    my $compressed = compress_blob($bytes);
    my $dir        = _dirname($path);
    my ($fh, $tmp) = tempfile("zstd-XXXXXX", DIR => $dir, UNLINK => 0);
    binmode $fh;
    print $fh $compressed
        or do { close $fh; unlink $tmp; croak "write to '$tmp' failed: $!" };
    close($fh)
        or do { unlink $tmp; croak "close '$tmp' failed: $!" };
    rename($tmp, $path)
        or do { unlink $tmp; croak "rename '$tmp' -> '$path' failed: $!" };

    return $path;
}

sub decompress_file {
    my ($path) = @_;

    open(my $fh, '<', $path) or croak "open '$path': $!";
    binmode $fh;
    local $/;
    my $bytes = <$fh>;
    close $fh;

    return decompress_blob($bytes);
}

sub _dirname {
    my ($path) = @_;
    my (undef, $dir) = File::Spec->splitpath($path);
    return length($dir) ? $dir : '.';
}

# ---------------------------------------------------------------------------
# Streaming writer / reader for jsonl-style append-safe access.

sub open_zstd_writer {
    my ($path) = @_;
    require Test2::Harness2::Util::Zstd::Writer;
    return Test2::Harness2::Util::Zstd::Writer->_open($path);
}

sub open_zstd_reader {
    my ($path) = @_;
    require Test2::Harness2::Util::Zstd::Reader;
    return Test2::Harness2::Util::Zstd::Reader->_open($path);
}

# zstd_frame_size($bytes) -- return the on-disk byte length of the
# first zstd frame in $bytes, or undef if $bytes does not yet contain
# a complete frame. Used by the dict-mode reader to find frame
# boundaries without scanning for magic (which can race on partial
# writes). Implements RFC 8878 frame_header parsing.
sub zstd_frame_size {
    my ($bytes) = @_;

    return undef if length($bytes) < 6;
    return undef unless substr($bytes, 0, 4) eq ZSTD_FRAME_MAGIC;

    my $pos  = 4;
    my $desc = ord(substr($bytes, $pos, 1));
    $pos++;

    my $fcs_flag        = ($desc >> 6) & 0x3;
    my $single_segment  = ($desc >> 5) & 0x1;
    my $checksum_flag   = ($desc >> 2) & 0x1;
    my $dict_id_flag    = $desc & 0x3;

    # Window_Descriptor is absent when single_segment is set.
    if (!$single_segment) {
        return undef if length($bytes) < $pos + 1;
        $pos++;
    }

    # Dictionary_ID field size.
    my @dict_id_bytes = (0, 1, 2, 4);
    my $did_size = $dict_id_bytes[$dict_id_flag];
    return undef if length($bytes) < $pos + $did_size;
    $pos += $did_size;

    # Frame_Content_Size field size: depends on fcs_flag and single_segment.
    # fcs_flag=0: 1 byte if single_segment, else 0 bytes.
    # fcs_flag=1: 2 bytes.
    # fcs_flag=2: 4 bytes.
    # fcs_flag=3: 8 bytes.
    my @fcs_sizes = (
        $single_segment ? 1 : 0,
        2,
        4,
        8,
    );
    my $fcs_size = $fcs_sizes[$fcs_flag];
    return undef if length($bytes) < $pos + $fcs_size;
    $pos += $fcs_size;

    # Walk blocks until Last_Block is set.
    while (1) {
        return undef if length($bytes) < $pos + 3;
        my $b0 = ord(substr($bytes, $pos,     1));
        my $b1 = ord(substr($bytes, $pos + 1, 1));
        my $b2 = ord(substr($bytes, $pos + 2, 1));

        my $block_header = $b0 | ($b1 << 8) | ($b2 << 16);
        my $last_block   = $block_header & 0x1;
        my $block_type   = ($block_header >> 1) & 0x3;
        my $block_size   = $block_header >> 3;

        $pos += 3;

        if ($block_type == 1) {
            # RLE: 1 data byte regardless of block_size.
            return undef if length($bytes) < $pos + 1;
            $pos += 1;
        }
        else {
            # Raw (0) or Compressed (2): block_size data bytes follow.
            # Block_Type 3 is Reserved -- treat the same as far as
            # advancement goes (frame is malformed but we still need
            # to advance to avoid infinite loop).
            return undef if length($bytes) < $pos + $block_size;
            $pos += $block_size;
        }

        last if $last_block;
    }

    if ($checksum_flag) {
        return undef if length($bytes) < $pos + 4;
        $pos += 4;
    }

    return $pos;
}
1;

__END__

=pod

=encoding UTF-8

=head1 NAME

Test2::Harness2::Util::Zstd - zstd helpers (compress, decompress, append-safe writer, line reader).

=head1 SYNOPSIS

    use Test2::Harness2::Util::Zstd qw{
        compress_blob
        decompress_blob
        compress_file_atomic
        decompress_file
        open_zstd_writer
        open_zstd_reader
    };

    my $frame = compress_blob($bytes);
    my $back  = decompress_blob($frame);

    compress_file_atomic('foo.json.zst', $json_text);
    my $bytes = decompress_file('foo.json.zst');

    my $w = open_zstd_writer('events.jsonl.zst');
    $w->print($json_line, "\n");

    my $r = open_zstd_reader('events.jsonl.zst');
    while (defined(my $line = $r->readline)) { ... }

=head1 DESCRIPTION

Single-purpose helper module wrapping L<Compress::Zstd> for the use
cases the harness actually has. Compression is always in-process via
the Perl module -- there is no external C<zstd> binary fallback.

All helpers run at the L<Compress::Zstd> library default level (3).
The custom shipped dictionary was benchmarked at well under a 35%
compression-ratio improvement over dict-less compression on a
representative event-log corpus and was dropped; these helpers no
longer accept any C<dict_*> options.

=over 4

=item compress_blob($bytes) :Bytes

One-shot compress.

=item decompress_blob($bytes) :Bytes

Symmetric one-shot decompress. Croaks on malformed input.

=item compress_file_atomic($path, $bytes) :Path

Compress C<$bytes> as one zstd frame, write to C<$path.tmp.XXXX> in
the same directory, then atomic-rename to C<$path>. Used for JSON
snapshot files (whole-file rewrite).

=item decompress_file($path) :Bytes

Read C<$path>, decompress, return the plaintext.

=item open_zstd_writer($path) :Object

Returns a writer object. C<-E<gt>print(@list)> compresses the
concatenation of C<@list> as one zstd frame and atomically appends
that frame to C<$path>. C<-E<gt>say(@list)> appends a trailing
newline. Each call writes one self-contained frame, so concurrent
appenders are safe as long as a frame fits in C<PIPE_BUF> (4 KiB on
Linux).

=item open_zstd_reader($path) :Object

Returns a L<Test2::Harness2::Util::Zstd::Reader> instance whose
C<-E<gt>readline> yields one decoded line at a time. The reader uses
a long-lived streaming L<Compress::Zstd::Decompressor>; framing is
recovered via the RFC-8878 frame-header parser in this module's
L</zstd_frame_size>.

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

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

See L<http://dev.perl.org/licenses/>

=cut
