package App::Yath2::Renderer::ArtifactWriter;
use strict;
use warnings;

our $VERSION = '2.000013';

use Exporter qw/import/;
our @EXPORT_OK = qw/write_artifact_atomic update_meta_formatters/;

use Carp qw/croak/;
use Fcntl qw/O_WRONLY O_CREAT O_EXCL :flock/;
use File::Spec ();
use File::Basename qw/dirname basename/;
use Errno qw/EEXIST/;

use Test2::Harness2::Util qw/lock_file unlock_file/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

# Write $bytes to $target atomically via exclusive-create tempfile + link(2).
#
# Returns 1 on successful publication.
# Returns 0 when $target already exists (existing-file-wins; no overwrite).
#
# Guarantee: readers never observe a partial file at $target. The tempfile
# is fully written and fsync'd before link(2) is attempted. Narrow
# durability: power-loss durability across the link (directory fsync) is
# NOT promised.
#
# The caller is responsible for the final filename, including any
# compression suffix (e.g. "events.txt" or "events.txt.zst"). This helper
# does not inspect the content.
sub write_artifact_atomic {
    my ($target, $bytes) = @_;
    return 0 if -e $target;

    my $dir  = dirname($target);
    my $name = basename($target);

    # Exclusive-create of the tempfile. Retry with a distinguishing suffix
    # on unlikely collisions (same PID, same second, same directory).
    my $fh;
    my $tmp;
    for my $try (0 .. 4) {
        my $suffix = $try ? ".$try" : "";
        $tmp = File::Spec->catfile($dir, ".tmp.$name.$$." . time() . $suffix);
        if (sysopen($fh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
            last;
        }
        $fh = undef;
    }
    die "could not create tempfile near $target: $!" unless $fh;

    # Full-write loop: syswrite may return fewer bytes than requested.
    my $off = 0;
    my $len = length $bytes;
    while ($off < $len) {
        my $w = syswrite($fh, $bytes, $len - $off, $off);
        unless (defined $w) {
            unlink $tmp;
            die "write tempfile $tmp: $!";
        }
        last if $w == 0;
        $off += $w;
    }
    if ($off != $len) {
        unlink $tmp;
        die "short write to tempfile $tmp ($off/$len)";
    }

    # File-level fsync: readers must not observe partial content.
    # IO::Handle->sync maps to fsync(2) on most platforms.
    # best-effort: some platforms / filesystems cannot sync; ignore failures.
    eval { require IO::Handle; $fh->sync };

    close($fh) or do {
        my $err = $!;
        unlink $tmp;
        die "close tempfile $tmp: $err";
    };

    # Atomic publish via link(2). EEXIST means another writer published
    # first; we lose the race gracefully and return 0.
    if (link($tmp, $target)) {
        unlink $tmp;
        return 1;
    }
    my $link_err = $!;
    my $eexist   = $!{EEXIST};    # capture before unlink(2) can clobber $!
    unlink $tmp;
    return 0 if $eexist;
    die "link($tmp, $target): $link_err";
}

# update_meta_formatters($logdir, \%map) — merge \%map into the
# meta.json's `formatters` hash, atomically.
#
# $logdir is the log's root directory (the directory that contains
# meta.json). \%map is { formatter_name => version, ... } and is
# merged into the existing { formatters => { ... } } block. Existing
# entries with names not in \%map are preserved.
#
# Returns the merged hash that was written.
#
# Mechanism: flock-bracketed read-modify-write of meta.json, with the
# new bytes published via the same exclusive-create-tempfile + rename
# dance as write_artifact_atomic. Unlike that helper, the rename here
# IS allowed to overwrite (meta.json is mutable; an existing file is
# the expected case, not a race-loss).
#
# Returns nothing when $logdir has no meta.json — formatter-version
# tracking is silently skipped for logs that predate the schema. The
# caller does not need to check the log layout themselves.
sub update_meta_formatters {
    my ($logdir, $map) = @_;
    croak "logdir is required"        unless defined $logdir && length $logdir;
    croak "formatter map is required" unless ref($map) eq 'HASH';

    my $meta_path = File::Spec->catfile($logdir, 'meta.json');
    return unless -e $meta_path;

    # Lock the existing meta.json for the read-modify-write window.
    # Other writers (e.g. concurrent reformat passes) cooperatively
    # serialise on this lock.
    my $lock_fh = lock_file($meta_path, '<', LOCK_EX);

    # Read current meta.
    my $meta;
    {
        open(my $rfh, '<', $meta_path) or do {
            unlock_file($lock_fh);
            die "open $meta_path for read: $!";
        };
        local $/;
        my $raw = <$rfh>;
        close $rfh;
        my $ok = eval { $meta = decode_json($raw); 1 };
        unless ($ok) {
            my $err = $@;
            unlock_file($lock_fh);
            die "decode meta.json at $meta_path: $err";
        }
    }

    # Merge $map into $meta->{formatters}, preserving entries not in $map.
    $meta->{formatters} //= {};
    for my $name (keys %$map) {
        $meta->{formatters}{$name} = $map->{$name};
    }

    # Serialise + atomic publish via tempfile + rename. Plain rename is
    # allowed to overwrite the existing meta.json.
    my $bytes = encode_json($meta);

    my $dir  = dirname($meta_path);
    my $name = basename($meta_path);
    my $tmp  = File::Spec->catfile($dir, ".tmp.$name.$$." . time());

    my $wfh;
    unless (sysopen($wfh, $tmp, O_WRONLY | O_CREAT | O_EXCL, 0644)) {
        unlock_file($lock_fh);
        die "create tempfile $tmp: $!";
    }

    my $written = print {$wfh} $bytes;
    unless ($written) {
        my $err = $!;
        close $wfh;
        unlink $tmp;
        unlock_file($lock_fh);
        die "write $tmp: $err";
    }

    eval { require IO::Handle; $wfh->sync };
    unless (close $wfh) {
        my $err = $!;
        unlink $tmp;
        unlock_file($lock_fh);
        die "close $tmp: $err";
    }

    unless (rename($tmp, $meta_path)) {
        my $err = $!;
        unlink $tmp;
        unlock_file($lock_fh);
        die "rename $tmp -> $meta_path: $err";
    }

    unlock_file($lock_fh);

    return $meta->{formatters};
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer::ArtifactWriter - Atomic artifact file publication

=head1 SYNOPSIS

    use App::Yath2::Renderer::ArtifactWriter qw/write_artifact_atomic/;

    # Publish plain bytes.
    my $rc = write_artifact_atomic("/run/dir/events.txt", $bytes);

    # Caller passes the compression-visible filename when bytes are
    # already compressed.
    my $rc = write_artifact_atomic("/run/dir/events.txt.zst", $zst_bytes);

    if ($rc) {
        # We published the file.
    }
    else {
        # Another writer won the race; $target already exists.
    }

=head1 DESCRIPTION

Provides C<write_artifact_atomic>, a single exported function that writes
a byte string to a target path in a way that guarantees readers never
observe a partial file. It is safe to call concurrently from multiple
processes targeting the same path: the first writer wins and subsequent
writers silently return C<0> rather than corrupting the file.

Mechanism: an exclusive-create tempfile is opened in the same directory
as the target, bytes are written in a full-write loop (handling short
C<syswrite> returns), the file is C<fsync>'d at the file level, and
then C<link(2)> atomically publishes it. Because C<link(2)> fails with
C<EEXIST> if the target already exists, the existing file always wins
in a race.

B<Narrow durability guarantee>: readers never see partial content.
Power-loss durability across the C<link> (directory C<fsync>) is I<not>
promised.

The caller is responsible for choosing the final filename, including
any compression suffix such as C<.zst>. This helper does not inspect
or transform the byte content in any way.

=head1 EXPORTS

Nothing is exported by default.

=over 4

=item write_artifact_atomic($target, $bytes)

Writes C<$bytes> to C<$target> atomically.

Returns C<1> on successful publication. Returns C<0> when C<$target>
already exists (existing-file-wins; no overwrite, no error). Dies on any
unrecoverable I/O failure.

=item update_meta_formatters($logdir, \%map)

Merge C<\%map> (a C<< { formatter_name => version, ... } >> hash) into
the C<formatters> block of C<meta.json> in C<$logdir>. Existing
entries not mentioned in C<\%map> are preserved.

The read-modify-write is bracketed by C<flock(LOCK_EX)> on C<meta.json>
itself so concurrent reformat passes serialise cleanly, and the new
bytes are published via C<tempfile + rename> so a partial file is never
visible. Returns the merged C<formatters> hash that was written.

Silently no-ops when C<$logdir> has no C<meta.json> — formatter-version
tracking is skipped for logs that predate the schema. Callers do not
need to probe the layout themselves.

=back

=head1 SOURCE

The source code repository for Test2-Harness can be found at
L<http://github.com/Test-More/Test2-Harness/>.

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
