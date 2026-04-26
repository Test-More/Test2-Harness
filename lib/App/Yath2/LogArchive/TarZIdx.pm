package App::Yath2::LogArchive::TarZIdx;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Compress::Zstd ();
use Exporter qw/import/;
use Fcntl qw/SEEK_END SEEK_SET/;
use File::Find ();
use File::Spec ();
use Role::Tiny::With;

use App::Yath2::LogArchive::Format qw/TAR_ZIDX_MAGIC TAR_ZIDX_FOOTER_LEN/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

# This single module covers the on-disk tar.zidx format for both
# read (this package, App::Yath2::LogArchive::TarZIdx) and write
# (App::Yath2::LogArchive::Writer::TarZIdx, defined further down).
# The previous TarZIdx/External.pm + TarZIdx/PP.pm + TarZIdx/Util.pm
# + Writer/TarZIdx.pm split existed to gate Compress::Zstd vs the
# zstd binary fallback; that fallback is gone (Compress::Zstd is a
# hard prereq now), so a single module is simpler.

use constant BLOCK_SIZE        => 512;
use constant INDEX_ENTRY_NAME  => '__index__.json.zst';
use constant DICT_ENTRY_NAME   => 'zstd-dict.bin';

our @EXPORT_OK = qw/
    pack_ustar_header
    pack_footer
    parse_footer
    pad_to_block
    zstd_compress
    zstd_decompress
    BLOCK_SIZE
    INDEX_ENTRY_NAME
    DICT_ENTRY_NAME
/;

# ----------------------------------------------------------------------
# Format helpers (formerly TarZIdx/Util.pm).

sub pack_ustar_header {
    my ($name, $size) = @_;

    my ($base, $prefix) = ($name, '');
    if (length($name) > 100) {
        my $i = rindex($name, '/', 154);
        croak "tar.zidx: pathname too long for ustar: $name"
            if $i < 0
            || (length($name) - $i - 1) > 100
            || $i > 155;
        $prefix = substr($name, 0, $i);
        $base   = substr($name, $i + 1);
    }

    my $hdr = pack(
        'a100 a8 a8 a8 a12 a12 A8 a1 a100 a6 a2 a32 a32 a8 a8 a155 x12',
        $base,
        sprintf('%07o',  oct('0644')) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%011o', $size) . "\0",
        sprintf('%011o', time) . "\0",
        '        ',
        '0',
        '',
        "ustar\0",
        '00',
        '',
        '',
        sprintf('%07o', 0) . "\0",
        sprintf('%07o', 0) . "\0",
        $prefix,
    );

    my $sum = unpack('%16C*', $hdr);
    substr($hdr, 148, 8) = sprintf('%06o', $sum) . "\0 ";

    croak "tar.zidx: header pack produced unexpected length"
        unless length($hdr) == BLOCK_SIZE;

    return $hdr;
}

sub pad_to_block {
    my ($len) = @_;
    my $rem = $len % BLOCK_SIZE;
    return $rem ? (BLOCK_SIZE - $rem) : 0;
}

sub pack_footer {
    my ($idx_offset, $idx_size) = @_;
    return pack('a8 Q< Q< Q<', TAR_ZIDX_MAGIC, $idx_offset, $idx_size, 0);
}

sub parse_footer {
    my ($buf) = @_;
    croak "tar.zidx: short footer" unless length($buf) == TAR_ZIDX_FOOTER_LEN;
    my ($magic, $idx_offset, $idx_size, undef) = unpack('a8 Q< Q< Q<', $buf);
    croak "tar.zidx: bad footer magic" unless $magic eq TAR_ZIDX_MAGIC;
    return ($idx_offset, $idx_size);
}

# zstd_compress / zstd_decompress are thin wrappers around
# Compress::Zstd. They exist for the index payload (which is
# zstd-compressed JSON) and never appear on a hot path.
sub zstd_compress {
    my ($bytes) = @_;
    my $out = Compress::Zstd::compress($bytes);
    croak "tar.zidx: Compress::Zstd::compress failed" unless defined $out;
    return $out;
}

sub zstd_decompress {
    my ($bytes) = @_;
    my $out = Compress::Zstd::decompress($bytes);
    croak "tar.zidx: Compress::Zstd::decompress failed" unless defined $out;
    return $out;
}

# ----------------------------------------------------------------------
# Reader.

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path format _index +_dict_bytes +_dict_loaded/;

with 'App::Yath2::LogArchive::Role::Source';

# Compress::Zstd is a hard prereq (per the zstd-loggers spec, stage
# 1), so the reader is always viable.
sub viable { 1 }

sub _build_index {
    my $self = shift;
    return $self->{+_INDEX} if $self->{+_INDEX};

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;

    my $size = -s $self->{+PATH};
    croak "tar.zidx: file too small" if $size < TAR_ZIDX_FOOTER_LEN;

    seek($fh, -TAR_ZIDX_FOOTER_LEN, SEEK_END) or croak "seek footer: $!";
    my $foot;
    read($fh, $foot, TAR_ZIDX_FOOTER_LEN) == TAR_ZIDX_FOOTER_LEN
        or croak "short footer read";

    my ($idx_offset, $idx_size) = parse_footer($foot);

    seek($fh, $idx_offset, SEEK_SET) or croak "seek index: $!";
    my $idx_bytes;
    read($fh, $idx_bytes, $idx_size) == $idx_size
        or croak "short index read";
    close $fh;

    my $json = zstd_decompress($idx_bytes);
    $self->{+_INDEX} = decode_json($json);
    return $self->{+_INDEX};
}

sub list_files {
    my $self = shift;
    return keys %{$self->_build_index};
}

sub has_file {
    my ($self, $rel) = @_;
    return exists $self->_build_index->{$rel} ? 1 : 0;
}

# Role::Source dict_bytes contract for the tar.zidx backend.
# Returns the bytes of the bundled zstd dictionary (the file the
# writer copied out of $source/zstd-dict.bin) or undef when the
# archive is dict-less. Probes the index once and caches the result;
# never falls back to the install share.
sub dict_bytes {
    my $self = shift;
    return $self->{+_DICT_BYTES} if $self->{+_DICT_LOADED};
    $self->{+_DICT_LOADED} = 1;

    my $entry = $self->_build_index->{DICT_ENTRY_NAME()};
    return $self->{+_DICT_BYTES} = undef unless $entry;

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek dict: $!";
    my $bytes;
    read($fh, $bytes, $entry->{size}) == $entry->{size}
        or croak "short dict read";
    close $fh;

    return $self->{+_DICT_BYTES} = $bytes;
}

sub read_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel}
        or croak "no such file '$rel' in archive";

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $stored;
    read($fh, $stored, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;

    # 'inner' tells us whether the entry's payload is itself
    # zstd-compressed (legacy default) or stored verbatim. Verbatim
    # entries cover both already-.zst source files and the bundled
    # dictionary; compressed entries cover anything that was a
    # plaintext file in the source logdir.
    my $inner = $entry->{inner} // 'zstd';
    my $plain = $inner eq 'none' ? $stored : zstd_decompress($stored);

    open(my $sfh, '<', \$plain) or croak "open scalar: $!";
    return $sfh;
}

sub close {
    my $self = shift;
    delete $self->{+_INDEX};
    delete $self->{+_DICT_BYTES};
    delete $self->{+_DICT_LOADED};
}

# ----------------------------------------------------------------------
# Writer.

package App::Yath2::LogArchive::Writer::TarZIdx;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Find ();
use File::Spec ();
use Role::Tiny::With;

use Object::HashBase qw/source path format/;

use Test2::Harness2::Util::JSON qw/encode_json/;

with 'App::Yath2::LogArchive::Role::Writer';

sub viable {
    my ($class, $format) = @_;
    return 0 unless defined $format && $format eq 'tar.zidx';
    return 1;
}

sub write_archive {
    my $self = shift;

    my $src = $self->{+SOURCE};
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $abs_src = File::Spec->rel2abs($src);
    croak "source '$src' is not a directory" unless -d $abs_src;

    open(my $fh, '>', $tmp) or croak "open $tmp: $!";
    binmode $fh;

    my @entries;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = File::Spec->abs2rel($_, $abs_src);
                $rel =~ s{\\}{/}g;
                push @entries => [$rel, $_];
            },
        },
        $abs_src,
    );

    my %index;
    for my $pair (sort { $a->[0] cmp $b->[0] } @entries) {
        my ($rel, $abs) = @$pair;

        open(my $rfh, '<', $abs) or croak "open $abs: $!";
        binmode $rfh;
        local $/;
        my $raw = <$rfh>;
        close $rfh;

        # Already-zstd-compressed source files (the loggers' .json.zst
        # / .jsonl.zst, plus the bundled zstd-dict.bin) are stored
        # verbatim with inner=>'none'. Everything else is wrapped in
        # an inner zstd frame and recorded as inner=>'zstd', matching
        # the historical default.
        my $is_zst = ($rel =~ /\.zst\z/) || ($rel eq App::Yath2::LogArchive::TarZIdx::DICT_ENTRY_NAME());
        my ($payload, $stored, $inner);
        if ($is_zst) {
            $payload = $raw;
            $stored  = $rel;
            $inner   = 'none';
        }
        else {
            $payload = App::Yath2::LogArchive::TarZIdx::zstd_compress($raw);
            $stored  = "$rel.zst";
            $inner   = 'zstd';
        }

        my $hdr = App::Yath2::LogArchive::TarZIdx::pack_ustar_header(
            $stored, length($payload),
        );
        print $fh $hdr;
        my $data_offset = tell $fh;
        print $fh $payload;
        my $pad = App::Yath2::LogArchive::TarZIdx::pad_to_block(length $payload);
        print $fh ("\0" x $pad) if $pad;

        $index{$rel} = {
            stored => $stored,
            offset => $data_offset,
            size   => length $payload,
            inner  => $inner,
        };
    }

    my $idx_json       = encode_json(\%index);
    my $idx_compressed = App::Yath2::LogArchive::TarZIdx::zstd_compress($idx_json);
    my $idx_hdr        = App::Yath2::LogArchive::TarZIdx::pack_ustar_header(
        App::Yath2::LogArchive::TarZIdx::INDEX_ENTRY_NAME(),
        length($idx_compressed),
    );
    print $fh $idx_hdr;
    my $idx_offset = tell $fh;
    print $fh $idx_compressed;
    my $pad = App::Yath2::LogArchive::TarZIdx::pad_to_block(length $idx_compressed);
    print $fh ("\0" x $pad) if $pad;

    print $fh ("\0" x (App::Yath2::LogArchive::TarZIdx::BLOCK_SIZE() * 2));

    print $fh App::Yath2::LogArchive::TarZIdx::pack_footer(
        $idx_offset, length($idx_compressed),
    );

    close $fh or croak "close $tmp: $!";

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";
    return $out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive::TarZIdx - Reader and writer for the tar.zidx archive format.

=head1 DESCRIPTION

Single in-tree archive format yath produces and reads. On disk it is
a USTAR-format tar followed by a 32-byte footer; the tar carries
per-entry payloads (each individually zstd-compressed if the source
was plaintext, or stored verbatim if the source was already a
.zst-suffixed file or the bundled zstd dictionary) plus a special
index entry. The footer points at the index, which is a
zstd-compressed JSON map from relative path to entry metadata
(C<{stored, offset, size, inner}>).

C<inner> takes the values:

=over 4

=item C<zstd>

The entry's payload bytes are zstd-compressed. The reader
decompresses them on C<read_file>.

=item C<none>

The entry's payload is stored verbatim. The reader returns the
bytes as-is.

=back

The bundled zstd dictionary (C<zstd-dict.bin>) is always stored with
C<inner =E<gt> "none">. Consumers fetch it via C<-E<gt>dict_bytes>;
a missing entry means the archive was written dict-less and the
reader does not consult any other dict source.

=head1 PUBLIC INTERFACE

=over 4

=item Reader: C<App::Yath2::LogArchive::TarZIdx-E<gt>new(path =E<gt> $path)>

Returns a reader object. C<list_files>, C<has_file>, C<read_file>,
C<dict_bytes>, and C<close> behave per the
L<App::Yath2::LogArchive::Role::Source> contract.

=item Writer: C<App::Yath2::LogArchive::Writer::TarZIdx-E<gt>new(source =E<gt> $dir, path =E<gt> $out)-E<gt>write_archive>

Walks C<$dir>, writes a tar.zidx archive at C<$out>. C<$dir/zstd-dict.bin>,
when present, is bundled into the archive at the same path so
extracts and replays do not depend on the recipient's install
having a matching dict.

=back

=head1 SEE ALSO

L<App::Yath2::LogArchive::Format> -- magic bytes / footer constants.

L<Test2::Harness2::Util::Zstd> -- the zstd helper used by the
loggers; the format here is independent of that helper but uses
the same Compress::Zstd module under the hood.

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
