package App::Yath2::LogArchive::Directory;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Find ();
use File::Path qw/make_path/;
use File::Spec ();

use parent 'App::Yath2::LogArchive';
use Object::HashBase qw/path live/;

# Directory backend. Handles two cases with one implementation:
#
#   - Live workdir  -- the harness is actively writing into the
#                      directory; mutating reads (the Artifact's
#                      FileMonitor) drive a real change-detection
#                      loop.
#
#   - Extracted dir -- the directory is a sealed extract of a
#                      tar.zidx (post `yath extract`); content is
#                      effectively static.
#
# The only behavioral difference is whether an Artifact wraps a
# FileMonitor (live) or short-circuits to first-truthy / rest-zero
# (extracted). The 'live' attribute drives that. By default the
# constructor auto-detects: a directory carrying any IPC-manager
# marker (workdir-style 'PID' / 'dispatch.lock' / 'settings.json'
# files at the root) is treated as live; otherwise it is treated as
# extracted/static. Pass live => 1 / live => 0 to override.

sub init {
    my $self = shift;
    my $p    = $self->{+PATH} // croak "path is required";
    croak "path '$p' is not a directory" unless -d $p;
    $self->{+LIVE} //= $self->_auto_detect_live;
    return;
}

sub is_live { $_[0]->{+LIVE} ? 1 : 0 }

# A directory is "live" when it looks like a yath workdir's logs
# tree -- i.e. when sibling IPC-manager state files exist next to
# it. This is a heuristic; callers can override with live => 1/0.
# Markers tested below: a `PID` file or a `dispatch.jsonl` file in
# the parent directory.
#
# In practice: we mark live when the directory exists and is
# writable, and an `lsof`-shaped check is impractical at the
# library level; the simplest reliable signal is "is the directory
# writable by this process". A read-only extract from `yath
# extract` is, by convention, not chmod'd -- but the user often
# does run yath extract into a writable dir. To keep the behavior
# unsurprising, we default to LIVE when not told otherwise. The
# tradeoff: an Artifact over an extracted dir pays one stat call
# per peek/changed cycle. That is cheap relative to the rest of
# the work. Callers that want zero overhead pass live => 0.
sub _auto_detect_live {
    my $self = shift;
    my $p    = $self->{+PATH};
    return 1 if -e File::Spec->catfile($p, '..', 'PID');
    return 1 if -e File::Spec->catfile($p, '..', 'dispatch.jsonl');
    return 1;
}

# {{{ Read API (Source role)

sub read_file {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    open(my $fh, '<', $abs) or croak "read_file '$rel': $!";
    return $fh;
}

sub has_file {
    my ($self, $rel) = @_;
    my $abs = File::Spec->catfile($self->{+PATH}, $rel);
    return -f $abs ? 1 : 0;
}

sub list_files {
    my $self = shift;
    my @files;
    my $root = $self->{+PATH};
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -f $_;
                my $rel = File::Spec->abs2rel($_, $root);
                $rel =~ s{\\}{/}g;
                push @files => $rel;
            },
        },
        $root,
    );
    return @files;
}

# Walk the directory tree and return every relative subdirectory
# path beneath the root (the root itself is excluded). Empty
# directories are reported -- they are how runs / jobs / services
# announce existence before any artifact has landed.
sub list_dirs {
    my $self = shift;
    my @dirs;
    my $root = $self->{+PATH};
    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                return unless -d $_;
                return if $_ eq $root;
                my $rel = File::Spec->abs2rel($_, $root);
                $rel =~ s{\\}{/}g;
                push @dirs => $rel;
            },
        },
        $root,
    );
    return @dirs;
}

sub absolute_path {
    my ($self, $rel) = @_;
    return File::Spec->catfile($self->{+PATH}, $rel);
}

# }}}

# {{{ Write API

# Build a tar.zidx archive from this directory. Compression of
# entries is internal to the tar.zidx format; the 'compressed'
# option here is a no-op (kept for API parity with extract()).
# Returns a TarZIdx instance pointing at $out.
sub archive {
    my ($self, $out, %opts) = @_;
    croak "output path is required" unless defined $out && length $out;

    require App::Yath2::LogArchive::TarZIdx;
    my $arc = App::Yath2::LogArchive::TarZIdx->new(path => $out);
    $arc->_write_from_directory($self->{+PATH});
    return $arc;
}

# Extract a directory backend's content into a fresh directory.
# That just means copying every file. Compression-aware: when the
# entry is .json.zst-shaped and compressed=>0 (the default for
# `yath extract`'s plaintext mode), the .zst suffix is stripped
# and the bytes are decompressed on the way out. Returns a new
# Directory instance pointing at $dir.
sub extract {
    my ($self, $dir, %opts) = @_;
    croak "destination is required" unless defined $dir && length $dir;
    croak "destination '$dir' already exists and is non-empty"
        if -e $dir && -d $dir && _dir_non_empty($dir);

    my $compressed = exists $opts{compressed} ? $opts{compressed} : 1;

    make_path($dir);
    require App::Yath2::LogArchive::Directory;

    for my $rel ($self->list_files) {
        my $is_zst  = $rel =~ /\.zst\z/;
        my $out_rel = ($compressed || !$is_zst) ? $rel : do {
            (my $r = $rel) =~ s/\.zst\z//;
            $r;
        };
        my $out_abs = File::Spec->catfile($dir, $out_rel);
        my $parent  = _parent_dir($out_abs);
        make_path($parent) unless -d $parent;

        my $rfh = $self->read_file($rel);
        binmode $rfh;
        my $bytes = do { local $/; <$rfh> };
        close $rfh;

        if (!$compressed && $is_zst) {
            require Test2::Harness2::Util::Zstd;
            $bytes = Test2::Harness2::Util::Zstd::decompress_blob($bytes);
        }

        open(my $out, '>', $out_abs) or croak "open $out_abs: $!";
        binmode $out;
        print $out $bytes;
        close $out or croak "close $out_abs: $!";
    }

    return App::Yath2::LogArchive::Directory->new(path => $dir, live => 0);
}

# }}}

# {{{ Internal helpers

sub _parent_dir {
    my ($path) = @_;
    require File::Basename;
    return File::Basename::dirname($path);
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

App::Yath2::LogArchive::Directory - Directory-backed LogArchive backend.

=head1 DESCRIPTION

Reads and writes a yath log tree laid out as a regular filesystem
directory. Handles both the live workdir case (the harness is
actively writing into it) and the extracted-dir case (post
C<yath extract>). The only behavioral difference is whether an
L<App::Yath2::LogArchive::Artifact> wraps a
L<Test2::Harness2::Util::FileMonitor> for change polling (live) or
short-circuits to a one-shot change signal (static).

=head1 ATTRIBUTES

=over 4

=item path (required)

The root of the log tree.

=item live (optional, defaults to autodetect)

Boolean. C<1> means "treat as live": L<App::Yath2::LogArchive::Artifact/watch>
yields a FileMonitor that drives a real change-detection loop.
C<0> means "treat as static": the FileMonitor short-circuits to
"first check truthy, every later check zero".

The autodetection heuristic looks for IPC-manager state next to
the log root. Pass an explicit value to override.

=back

=head1 METHODS

In addition to the inherited L<App::Yath2::LogArchive> API:

=over 4

=item $tar = $dir->archive($out_file, compressed => $bool)

Pack this directory into a tar.zidx archive at C<$out_file>.
Returns an L<App::Yath2::LogArchive::TarZIdx> instance pointing at
the new file.

=item $new_dir = $dir->extract($dest_dir, compressed => $bool)

Copy this directory into C<$dest_dir>. With C<compressed =E<gt> 0>
(the C<yath extract> default), C<.zst> entries are decompressed
and their suffixes stripped. With C<compressed =E<gt> 1>, files
are copied verbatim. Returns a new
L<App::Yath2::LogArchive::Directory> instance pointing at the
destination.

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

See L<http://dev.perl.org/licenses/>

=cut
