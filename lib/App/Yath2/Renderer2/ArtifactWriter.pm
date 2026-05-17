package App::Yath2::Renderer2::ArtifactWriter;
use strict;
use warnings;

our $VERSION = '2.000013';

use Exporter qw/import/;
our @EXPORT_OK = qw/write_artifact_atomic/;

use Fcntl qw/O_WRONLY O_CREAT O_EXCL/;
use File::Spec ();
use File::Basename qw/dirname basename/;
use Errno qw/EEXIST/;

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
    my $ok       = eval { require IO::Handle; $fh->sync; 1 };
    my $sync_err = $@;

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
    unlink $tmp;
    return 0 if $!{EEXIST};
    die "link($tmp, $target): $link_err";
}

1;

__END__

=pod

=encoding UTF-8

=head1 NAME

App::Yath2::Renderer2::ArtifactWriter - Atomic artifact file publication

=head1 SYNOPSIS

    use App::Yath2::Renderer2::ArtifactWriter qw/write_artifact_atomic/;

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

This module lives under the transitional C<Renderer2> namespace. It will
be renamed to C<App::Yath2::Renderer::ArtifactWriter> when the legacy
renderer is removed in stage 9.10.

=head1 EXPORTS

Nothing is exported by default.

=over 4

=item write_artifact_atomic($target, $bytes)

Writes C<$bytes> to C<$target> atomically.

Returns C<1> on successful publication. Returns C<0> when C<$target>
already exists (existing-file-wins; no overwrite, no error). Dies on any
unrecoverable I/O failure.

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
