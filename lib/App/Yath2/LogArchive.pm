package App::Yath2::LogArchive;
use strict;
use warnings;

our $VERSION = '2.000011';

use Carp qw/croak/;
use File::Path qw/make_path/;
use File::Spec ();
use File::Temp qw/tempdir/;

# HAS_* gating keeps optional format deps out of normal yath test
# paths: only `yath archive ...` / `yath test --archive=...` /
# etc. invocations pull these in. See Dependency Rules in CLAUDE.md.
use constant HAS_ARCHIVE_TAR => eval { require Archive::Tar;        1 } ? 1 : 0;
use constant HAS_GZIP        => eval { require IO::Compress::Gzip;  1 } ? 1 : 0;
use constant HAS_BZIP2       => eval { require IO::Compress::Bzip2; 1 } ? 1 : 0;
use constant HAS_ARCHIVE_ZIP => eval { require Archive::Zip;        1 } ? 1 : 0;

# .7z is intentionally shelled-out to the `7z` binary rather than
# pulled in as a CPAN dep. Detection checks $PATH once at BEGIN so
# HAS_7Z stays a genuine compile-time constant.
use constant HAS_7Z => do {
    my $found;
    for my $dir (split /:/, $ENV{PATH} // '') {
        next unless length $dir;
        my $cand = File::Spec->catfile($dir, '7z');
        if (-x $cand) { $found = 1; last }
    }
    $found ? 1 : 0;
};

# Formats the archive layer ships support for. Each entry:
#   gated_by  -- constant predicate checked at runtime
#   ext       -- canonical filename extension (for sanity checks)
#   write     -- coderef (class, %args) that writes the archive
#   read      -- coderef (class, %args) that extracts to a tempdir
my %FORMATS;

sub supported_formats {
    my $class = shift;
    return grep { $FORMATS{$_}{gated_by}->() } sort keys %FORMATS;
}

sub format_is_supported {
    my ($class, $format) = @_;
    my $entry = $FORMATS{$format} or return 0;
    return $entry->{gated_by}->() ? 1 : 0;
}

# Atomic writes: assemble under $archive.pend, rename into place on
# success. This keeps an interrupted create from leaving a
# half-complete archive at the target path.
sub create {
    my $class = shift;
    my %args  = @_;

    my $logdir  = $args{logdir}  // croak "'logdir' is required";
    my $archive = $args{archive} // croak "'archive' is required";
    my $format  = $args{format}  // $class->_infer_format($archive);

    croak "logdir '$logdir' does not exist or is not a directory"
        unless -d $logdir;

    my $entry = $FORMATS{$format}
        or croak "unsupported archive format '$format'. Supported: " . join(', ', $class->supported_formats);

    croak "format '$format' requires an optional dependency that is not installed " . "(see App::Yath2::LogArchive's POD for what each format needs)"
        unless $entry->{gated_by}->();

    my $pend = "$archive.pend";
    unlink $pend if -e $pend;

    my $ok = eval {
        $entry->{write}->(
            $class,
            logdir  => $logdir,
            archive => $pend,
        );
        rename($pend, $archive) or die "rename '$pend' -> '$archive': $!\n";
        1;
    };
    my $err = $@;

    unless ($ok) {
        unlink $pend if -e $pend;
        die $err;
    }

    return $archive;
}

# Extract returns a path to a logs/-rooted directory tree. When the
# caller did not supply a destination we extract into a tempdir
# owned by whichever File::Temp object we return; callers that want
# a specific destination pass `destination => $path`.
sub extract {
    my $class = shift;
    my %args  = @_;

    my $archive = $args{archive} // croak "'archive' is required";
    my $format  = $args{format}  // $class->_infer_format($archive);

    croak "archive '$archive' does not exist"
        unless -f $archive;

    my $entry = $FORMATS{$format}
        or croak "unsupported archive format '$format'. Supported: " . join(', ', $class->supported_formats);

    croak "format '$format' requires an optional dependency that is not installed"
        unless $entry->{gated_by}->();

    my $dest = $args{destination};
    my $guard;
    if (!defined $dest) {
        $dest = tempdir("yath-archive-extract-XXXXXXXX", TMPDIR => 1, CLEANUP => 1);
    }
    else {
        make_path($dest) unless -d $dest;
    }

    $entry->{read}->(
        $class,
        archive     => $archive,
        destination => $dest,
    );

    return $dest;
}

# Use the archive's extension to infer a format when the caller did
# not pass one explicitly. Multi-dot extensions (.tar.gz, .tar.bz2)
# are recognised first.
sub _infer_format {
    my ($class, $path) = @_;

    return 'tar.gz'  if $path =~ /\.tar\.gz\z/i  || $path =~ /\.tgz\z/i;
    return 'tar.bz2' if $path =~ /\.tar\.bz2\z/i || $path =~ /\.tbz2?\z/i;
    return 'zip'     if $path =~ /\.zip\z/i;
    return '7z'      if $path =~ /\.7z\z/i;

    croak "cannot infer archive format from '$path' (pass format => ...)";
}

# ----------------------------------------------------------------------
# Format implementations
# ----------------------------------------------------------------------

# Shared Archive::Tar helper. The resulting archive's root directory
# is "logs/" regardless of what the source directory is named on
# disk; that matches PLAN's "Logging changes" section 3 and
# simplifies extraction downstream (extracted tree always looks the
# same as a live workdir's logs/).
sub _tar_write {
    my ($class, %args) = @_;
    my $logdir   = $args{logdir};
    my $archive  = $args{archive};
    my $compress = $args{compress} // 0;    # 0 / 'gzip' / 'bzip2'

    my $tar = Archive::Tar->new;

    # Walk the logdir and add every file with 'logs/<rel>' as the
    # archive path. File::Find::wanted is avoided for determinism:
    # a sorted walk guarantees reproducible archives given the same
    # input tree.
    my @files = $class->_walk_files_sorted($logdir);
    for my $file (@files) {
        my $rel = File::Spec->abs2rel($file, $logdir);
        $tar->add_files($file);
        # Archive::Tar records paths verbatim; rename to 'logs/<rel>'.
        my @entries = $tar->get_files;
        $entries[-1]->rename("logs/$rel");
    }

    my %write_opts;
    if ($compress eq 'gzip') {
        $write_opts{COMPRESS} = Archive::Tar::COMPRESS_GZIP();
    }
    elsif ($compress eq 'bzip2') {
        $write_opts{COMPRESS} = Archive::Tar::COMPRESS_BZIP();
    }

    $tar->write($archive, %write_opts ? (values %write_opts) : ())
        or die "Archive::Tar write failed: " . $tar->error . "\n";

    return;
}

sub _tar_read {
    my ($class, %args) = @_;
    my $archive = $args{archive};
    my $dest    = $args{destination};

    my $tar = Archive::Tar->new;
    $tar->read($archive)
        or die "Archive::Tar read failed: " . $tar->error . "\n";

    # Extract inside $dest. Paths in the archive are 'logs/<rel>';
    # we recreate that tree rooted at $dest.
    my $cwd = File::Spec->rel2abs('.');
    chdir $dest or die "chdir '$dest': $!";
    my $ok  = eval { $tar->extract; 1 };
    my $err = $@;
    chdir $cwd or die "chdir '$cwd': $!";
    die $err unless $ok;

    return;
}

%FORMATS = (
    'tar.gz' => {
        gated_by => sub { HAS_ARCHIVE_TAR && HAS_GZIP },
        ext      => 'tar.gz',
        write    => sub { $_[0]->_tar_write(@_[1 .. $#_], compress => 'gzip') },
        read     => sub { $_[0]->_tar_read(@_[1 .. $#_]) },
    },
    'tar.bz2' => {
        gated_by => sub { HAS_ARCHIVE_TAR && HAS_BZIP2 },
        ext      => 'tar.bz2',
        write    => sub { $_[0]->_tar_write(@_[1 .. $#_], compress => 'bzip2') },
        read     => sub { $_[0]->_tar_read(@_[1 .. $#_]) },
    },
    'zip' => {
        gated_by => sub { HAS_ARCHIVE_ZIP },
        ext      => 'zip',
        write    => sub {
            my ($class, %args) = @_;
            my $logdir  = $args{logdir};
            my $archive = $args{archive};

            require Archive::Zip;
            my $zip = Archive::Zip->new;

            for my $file ($class->_walk_files_sorted($logdir)) {
                my $rel = File::Spec->abs2rel($file, $logdir);
                $zip->addFile($file, "logs/$rel");
            }

            my $status = $zip->writeToFileNamed($archive);
            die "Archive::Zip write returned status '$status'\n"
                unless $status == Archive::Zip::AZ_OK();
            return;
        },
        read => sub {
            my ($class, %args) = @_;
            my $archive = $args{archive};
            my $dest    = $args{destination};

            require Archive::Zip;
            my $zip = Archive::Zip->new;
            $zip->read($archive) == Archive::Zip::AZ_OK()
                or die "Archive::Zip read failed for '$archive'\n";

            for my $member ($zip->members) {
                my $name = $member->fileName;
                my $out  = File::Spec->catfile($dest, $name);

                if ($member->isDirectory) {
                    make_path($out);
                    next;
                }

                my $outdir = File::Spec->catpath((File::Spec->splitpath($out))[0, 1]);
                make_path($outdir);

                my $status = $zip->extractMember($member, $out);
                die "Archive::Zip extract failed for '$name'\n"
                    unless $status == Archive::Zip::AZ_OK();
            }
            return;
        },
    },
    '7z' => {
        gated_by => sub { HAS_7Z },
        ext      => '7z',
        write    => sub {
            my ($class, %args) = @_;
            my $logdir  = $args{logdir};
            my $archive = $args{archive};

            # 7z wants to be invoked from the parent of the content
            # tree so the archived paths are relative. We stage the
            # logdir into a tempdir as 'logs/' to match the
            # archive-root convention the other formats follow.
            my $parent = File::Spec->catdir($logdir, '..');
            $parent = File::Spec->rel2abs($parent);

            my $basename = (File::Spec->splitpath($logdir))[2];
            $basename = 'logs' unless length $basename;

            my @cmd    = ('7z', 'a', $archive, "$parent/$basename");
            my $status = system {$cmd[0]} @cmd;
            die "7z invocation failed (status $status)\n" if $status != 0;
            return;
        },
        read => sub {
            my ($class, %args) = @_;
            my $archive = $args{archive};
            my $dest    = $args{destination};

            my @cmd    = ('7z', 'x', "-o$dest", '-y', $archive);
            my $status = system {$cmd[0]} @cmd;
            die "7z extract failed (status $status)\n" if $status != 0;
            return;
        },
    },
);

# Deterministic walker: depth-first sorted file traversal. Returns
# absolute file paths only (no directories) so callers can stuff
# them into archive constructors without additional filtering.
sub _walk_files_sorted {
    my ($class, $dir) = @_;
    $dir = File::Spec->rel2abs($dir);

    my @out;
    my @queue = ($dir);
    while (@queue) {
        my $cur = shift @queue;
        opendir(my $dh, $cur) or die "opendir '$cur': $!";
        my @children = sort grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;

        for my $child (@children) {
            my $full = File::Spec->catfile($cur, $child);
            if (-d $full) {
                push @queue => $full;
            }
            elsif (-f $full) {
                push @out => $full;
            }
        }
    }

    return @out;
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::LogArchive - Create and extract archives of a yath
C<logs/> directory.

=head1 DESCRIPTION

Yath 2.0's on-disk artifact format is an archive-of-C<logs/>. The
archive's root is always C<logs/>; inside it mirrors the workdir's
C<logs/> tree (C<runs/<run_id>/>, C<services/>, C<collectors/>,
etc.). Extraction reproduces the same tree a live workdir exposes,
so downstream consumers (renderers, archivers, ad-hoc analysis) see
the same shape whether they are pointed at a live workdir or an
extracted archive.

Supported formats:

=over 4

=item tar.gz

Always supported (pure-Perl L<Archive::Tar> + L<IO::Compress::Gzip>).
Recommended default for portability.

=item tar.bz2

Supported when L<IO::Compress::Bzip2> is installed (it is in most
Perl distributions).

=item zip

Supported when L<Archive::Zip> is installed.

=item 7z

Supported when a C<7z> binary is on C<$PATH>. Shelled out rather
than depending on a CPAN module.

=back

The class exposes L</supported_formats> so callers can pick a
format they know will work:

    my @fmts = App::Yath2::LogArchive->supported_formats;

=head1 CLASS METHODS

=over 4

=item $archive = App::Yath2::LogArchive->create(logdir => $dir, archive => $path, format => $fmt?)

Package C<$dir>'s tree as C<logs/> inside C<$path>. Format is
inferred from the filename extension when not given explicitly
(C<.tar.gz>, C<.tar.bz2>, C<.zip>, C<.7z>). Dies on missing
dependencies or I/O failure. The write is atomic:
C<< $path.pend >> is produced first and renamed over C<$path> on
success, so an interrupted create does not leave a partial file
at the target.

=item $dir = App::Yath2::LogArchive->extract(archive => $path, destination => $dest?, format => $fmt?)

Extract C<$path> to C<$dest> (a default L<File::Temp::tempdir>
with CLEANUP when not supplied). Returns the destination path.
The extracted tree is rooted at C<$dest/logs/>.

=item @fmts = App::Yath2::LogArchive->supported_formats

Return the format names whose optional dependencies are currently
installed.

=item $bool = App::Yath2::LogArchive->format_is_supported($fmt)

Return true when C<$fmt> is recognised AND its optional
dependency is installed.

=back

=head1 STAGE 11 SCOPE

This stage introduces the archive utility only. No command yet
creates or consumes an archive; that wiring lands when a command
needs it (e.g. C<yath test --archive=out.tar.gz>, or a hypothetical
C<yath archive> / C<yath extract> pair).

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

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<https://dev.perl.org/licenses/>

=cut
