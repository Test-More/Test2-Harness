package App::Yath2::LogArchive::TarZIdx;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use Compress::Zstd ();
use Fcntl qw/SEEK_END SEEK_SET/;
use File::Basename qw/dirname/;
use File::Find ();
use File::Path qw/make_path/;
use File::Spec ();

use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path +_index/;

# tar.zidx is the single archive format yath produces. Layout:
# a USTAR-format tar with per-entry payloads (each individually
# zstd-compressed when the source was plaintext, or stored verbatim
# when the source was already a .zst-suffixed file), plus a special
# index entry, plus a 32-byte footer pointing at the index.
#
# This file owns both reading and writing of that format. Read and
# write methods are sectioned below; helpers shared by both live at
# the top.

use constant BLOCK_SIZE          => 512;
use constant INDEX_ENTRY_NAME    => '__index__.json.zst';
use constant TAR_ZIDX_MAGIC      => "YZIDXv1\0";
use constant TAR_ZIDX_FOOTER_LEN => 32;

sub is_live { 0 }

sub absolute_path {
    my ($self, $rel) = @_;
    croak "absolute_path is unavailable for the tar.zidx backend; "
        . "extract first or read via the LogArchive API ($rel)";
}

# {{{ Format helpers (methods so subclasses / future formats can override)

sub pack_ustar_header {
    my ($self, $name, $size, %opts) = @_;
    my $typeflag = $opts{typeflag} // '0';
    my $mode     = $opts{mode}     // oct('0644');

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
        sprintf('%07o',  $mode) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%07o',  0) . "\0",
        sprintf('%011o', $size) . "\0",
        sprintf('%011o', time) . "\0",
        '        ',
        $typeflag,
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
    my ($self, $len) = @_;
    my $rem = $len % BLOCK_SIZE;
    return $rem ? (BLOCK_SIZE - $rem) : 0;
}

sub pack_footer {
    my ($self, $idx_offset, $idx_size) = @_;
    return pack('a8 Q< Q< Q<', TAR_ZIDX_MAGIC, $idx_offset, $idx_size, 0);
}

sub parse_footer {
    my ($self, $buf) = @_;
    croak "tar.zidx: short footer" unless length($buf) == TAR_ZIDX_FOOTER_LEN;
    my ($magic, $idx_offset, $idx_size, undef) = unpack('a8 Q< Q< Q<', $buf);
    croak "tar.zidx: bad footer magic" unless $magic eq TAR_ZIDX_MAGIC;
    return ($idx_offset, $idx_size);
}

sub zstd_compress {
    my ($self, $bytes) = @_;
    my $out = Compress::Zstd::compress($bytes);
    croak "tar.zidx: Compress::Zstd::compress failed" unless defined $out;
    return $out;
}

sub zstd_decompress {
    my ($self, $bytes) = @_;
    my $out = Compress::Zstd::decompress($bytes);
    croak "tar.zidx: Compress::Zstd::decompress failed" unless defined $out;
    return $out;
}

# }}}

# {{{ Read API (Source role)

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

    my ($idx_offset, $idx_size) = $self->parse_footer($foot);

    seek($fh, $idx_offset, SEEK_SET) or croak "seek index: $!";
    my $idx_bytes;
    read($fh, $idx_bytes, $idx_size) == $idx_size
        or croak "short index read";
    close $fh;

    my $json = $self->zstd_decompress($idx_bytes);
    $self->{+_INDEX} = decode_json($json);
    return $self->{+_INDEX};
}

sub list_files {
    my $self = shift;
    my $idx  = $self->_build_index;
    return grep { ($idx->{$_}{kind} // 'file') eq 'file' } keys %$idx;
}

# Directory entries explicitly recorded in the archive plus every
# parent-of-a-file path. Parent derivation lets older archives
# (pre-empty-dir-tracking) still report the directory shape that
# their files imply.
sub list_dirs {
    my $self = shift;
    my $idx  = $self->_build_index;

    my %dirs;
    for my $rel (keys %$idx) {
        if (($idx->{$rel}{kind} // 'file') eq 'dir') {
            $dirs{$rel} = 1;
            next;
        }
        my @parts = split m{/}, $rel;
        pop @parts;
        for my $i (1 .. scalar @parts) {
            $dirs{join('/', @parts[0 .. $i - 1])} = 1;
        }
    }
    return keys %dirs;
}

sub has_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel};
    return 0 unless $entry;
    return 0 if ($entry->{kind} // 'file') eq 'dir';
    return 1;
}

sub read_file {
    my ($self, $rel) = @_;
    my $entry = $self->_build_index->{$rel}
        or croak "no such file '$rel' in archive";
    croak "'$rel' is a directory entry, not a file"
        if ($entry->{kind} // 'file') eq 'dir';

    open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
    binmode $fh;
    seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
    my $stored;
    read($fh, $stored, $entry->{size}) == $entry->{size}
        or croak "short data read for '$rel'";
    close $fh;

    # 'inner' tells us whether the entry's payload is itself
    # zstd-compressed (legacy default) or stored verbatim. Verbatim
    # entries cover already-.zst source files; compressed entries
    # cover anything that was a plaintext file in the source logdir.
    my $inner = $entry->{inner} // 'zstd';
    my $plain = $inner eq 'none' ? $stored : $self->zstd_decompress($stored);

    open(my $sfh, '<', \$plain) or croak "open scalar: $!";
    return $sfh;
}

# No close() method on the backend: tar.zidx instances hold no
# open filehandles between calls (every read_file open/closes a
# fresh fh), so there is nothing to release. The cached index is
# discarded automatically when the object is GC'd; consumers that
# want to invalidate the cache can do so via Object::HashBase's
# slot accessor.

# }}}

# {{{ Write API

# extract: walk the index, materialise every member into a directory.
# 'compressed=>0' (the default) decompresses zstd payloads on the way
# out and strips the .zst suffix from the resulting filenames.
# 'compressed=>1' preserves byte-for-byte (still strips one zstd
# layer if the entry was wrapped, since the in-archive format always
# zstd-compresses plaintext entries -- compressed=>1 just refers to
# the suffix).
sub extract {
    my ($self, $dir, %opts) = @_;
    croak "destination is required" unless defined $dir && length $dir;
    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $compressed = exists $opts{compressed} ? $opts{compressed} : 0;

    make_path($dir);
    require Test2::Harness2::Util::Zstd;
    require App::Yath2::LogArchive::Directory;

    my $index = $self->_build_index;
    for my $rel (sort keys %$index) {
        my $entry = $index->{$rel};

        if (($entry->{kind} // 'file') eq 'dir') {
            my $abs = File::Spec->catdir($dir, $rel);
            make_path($abs) unless -d $abs;
            next;
        }

        my $out_rel = $compressed ? "$rel.zst" : $rel;
        # `compressed=>1` keeps the original bytes (including the
        # outer zstd wrap); `compressed=>0` strips one layer and
        # emits the plaintext.
        my $out_abs = File::Spec->catfile($dir, $out_rel);
        my $parent  = dirname($out_abs);
        make_path($parent) unless -d $parent;

        # Read the stored entry bytes once.
        open(my $fh, '<', $self->{+PATH}) or croak "open $self->{+PATH}: $!";
        binmode $fh;
        seek($fh, $entry->{offset}, SEEK_SET) or croak "seek data: $!";
        my $stored;
        read($fh, $stored, $entry->{size}) == $entry->{size}
            or croak "short data read for '$rel'";
        close $fh;

        my $inner = $entry->{inner} // 'zstd';

        my $payload;
        if ($compressed) {
            # Caller wants the verbatim-suffixed bytes. If the
            # archive entry was zstd-wrapped (inner='zstd'), the
            # bytes already are .zst-shaped; emit them as-is. If
            # the entry was stored verbatim (inner='none'), the
            # source was already .zst -- still verbatim.
            $payload = $stored;
        }
        else {
            $payload = $inner eq 'none' ? $stored : $self->zstd_decompress($stored);

            # When the original source was already .zst (inner=='none')
            # and the caller asked for plaintext, the file extension
            # in the archive carries '.zst'. Decompress the payload
            # and strip the suffix from the output rel-path so the
            # extracted form is a real plaintext file.
            if ($inner eq 'none' && $rel =~ /\.zst\z/) {
                $payload = Test2::Harness2::Util::Zstd::decompress_blob($payload);
                (my $stripped = $rel) =~ s/\.zst\z//;
                $out_abs = File::Spec->catfile($dir, $stripped);
                $parent  = dirname($out_abs);
                make_path($parent) unless -d $parent;
            }
        }

        open(my $out, '>', $out_abs) or croak "open $out_abs: $!";
        binmode $out;
        print $out $payload;
        close $out or croak "close $out_abs: $!";
    }

    return App::Yath2::LogArchive::Directory->new(path => $dir, live => 0);
}

# archive on a TarZIdx is a no-op when called against an existing
# .yath; it returns $self. (The user-visible flow is to call ->archive
# on a Directory backend; that yields a TarZIdx pointing at the new
# file.)
sub archive {
    my ($self, $out, %opts) = @_;
    croak "Cannot archive a tar.zidx backend (already archived); "
        . "open the source directory and call ->archive on it instead";
}

# Internal: build a tar.zidx archive at this object's PATH from a
# source directory. Used by Directory->archive($out) which constructs
# a TarZIdx pointing at $out and then calls _write_from_directory.
sub _write_from_directory {
    my ($self, $src) = @_;
    my $out = $self->{+PATH};
    my $tmp = "$out.tmp.$$";

    my $abs_src = File::Spec->rel2abs($src);
    croak "source '$src' is not a directory" unless -d $abs_src;

    open(my $fh, '>', $tmp) or croak "open $tmp: $!";
    binmode $fh;

    my @file_entries;
    my @dir_entries;
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $rel = File::Spec->abs2rel($_, $abs_src);
                return if $rel eq '.';
                $rel =~ s{\\}{/}g;
                if (-f $_) {
                    push @file_entries => [$rel, $_];
                }
                elsif (-d $_) {
                    push @dir_entries => $rel;
                }
            },
        },
        $abs_src,
    );

    my %index;

    # Directory entries land first so the on-disk tar walks
    # parent-before-children. Empty payloads, typeflag '5'.
    for my $rel (sort @dir_entries) {
        my $stored = "$rel/";
        my $hdr    = $self->pack_ustar_header(
            $stored, 0,
            typeflag => '5',
            mode     => oct('0755'),
        );
        print $fh $hdr;
        my $data_offset = tell $fh;
        $index{$rel} = {
            stored => $stored,
            offset => $data_offset,
            size   => 0,
            inner  => 'none',
            kind   => 'dir',
        };
    }

    for my $pair (sort { $a->[0] cmp $b->[0] } @file_entries) {
        my ($rel, $abs) = @$pair;

        open(my $rfh, '<', $abs) or croak "open $abs: $!";
        binmode $rfh;
        local $/;
        my $raw = <$rfh>;
        close $rfh;

        # Already-zstd-compressed source files (the loggers'
        # .json.zst / .jsonl.zst) are stored verbatim with
        # inner=>'none'. Everything else is wrapped in an inner
        # zstd frame and recorded as inner=>'zstd', matching the
        # historical default.
        my $is_zst = ($rel =~ /\.zst\z/);
        my ($payload, $stored, $inner);
        if ($is_zst) {
            $payload = $raw;
            $stored  = $rel;
            $inner   = 'none';
        }
        else {
            $payload = $self->zstd_compress($raw);
            $stored  = "$rel.zst";
            $inner   = 'zstd';
        }

        my $hdr = $self->pack_ustar_header($stored, length($payload));
        print $fh $hdr;
        my $data_offset = tell $fh;
        print $fh $payload;
        my $pad = $self->pad_to_block(length $payload);
        print $fh ("\0" x $pad) if $pad;

        $index{$rel} = {
            stored => $stored,
            offset => $data_offset,
            size   => length $payload,
            inner  => $inner,
            kind   => 'file',
        };
    }

    my $idx_json       = encode_json(\%index);
    my $idx_compressed = $self->zstd_compress($idx_json);
    my $idx_hdr        = $self->pack_ustar_header(INDEX_ENTRY_NAME, length($idx_compressed));
    print $fh $idx_hdr;
    my $idx_offset = tell $fh;
    print $fh $idx_compressed;
    my $pad = $self->pad_to_block(length $idx_compressed);
    print $fh ("\0" x $pad) if $pad;

    print $fh ("\0" x (BLOCK_SIZE * 2));

    print $fh $self->pack_footer($idx_offset, length($idx_compressed));

    close $fh or croak "close $tmp: $!";

    rename($tmp, $out) or croak "rename $tmp -> $out: $!";

    # Force re-read of the index next time list_files / has_file
    # / read_file is called.
    delete $self->{+_INDEX};

    return $out;
}

sub _dir_non_empty {
    my ($dir) = @_;
    opendir(my $dh, $dir) or return 0;
    while (defined(my $entry = readdir($dh))) {
        next if $entry eq '.' || $entry eq '..';
        closedir($dh);
        return 1;
    }
    closedir($dh);
    return 0;
}

# }}}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive::TarZIdx - tar.zidx-backed LogArchive backend.

=head1 DESCRIPTION

Reads and writes the single in-tree archive format yath produces.
On disk the format is a USTAR-format tar followed by a 32-byte
footer; the tar carries per-entry payloads (each individually
zstd-compressed if the source was plaintext, or stored verbatim if
the source was already a C<.zst>-suffixed file) plus a special
index entry. The footer points at the index, which is a
zstd-compressed JSON map from relative path to entry metadata
(C<{stored, offset, size, inner}>).

C<inner> is C<'zstd'> when the entry's payload bytes are
zstd-compressed, or C<'none'> when the bytes are stored verbatim.

=head1 ATTRIBUTES

=over 4

=item path (required)

The path to the C<.yath> file.

=back

=head1 METHODS

In addition to the inherited L<App::Yath2::LogArchive> API:

=over 4

=item $new_dir = $tar->extract($dest_dir, compressed => $bool)

Extract the archive into a fresh directory. With
C<compressed =E<gt> 0> (the default for this backend, matching
C<yath extract>) every zstd-compressed member is decompressed on
the way out and the trailing C<.zst> suffix is stripped from the
output filename. With C<compressed =E<gt> 1> entries are written
verbatim with C<.zst> suffixes preserved. Returns a new
L<App::Yath2::LogArchive::Directory> instance pointing at the
destination.

=item C<archive> is unsupported on this backend

Calling L</archive> on a TarZIdx instance croaks. The user-visible
flow is to construct an L<App::Yath2::LogArchive::Directory> for
the source and call L<App::Yath2::LogArchive::Directory/archive>
on it; that yields a TarZIdx instance pointing at the new file.

=back

=head1 SEE ALSO

L<App::Yath2::LogArchive> -- the base class / factory.

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
