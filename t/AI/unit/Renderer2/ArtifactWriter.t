use Test2::V0;
use File::Temp qw/tempdir/;

use App::Yath2::Renderer2::ArtifactWriter qw/write_artifact_atomic/;

my $dir = tempdir(CLEANUP => 1);

# Fresh write succeeds.
my $rc = write_artifact_atomic("$dir/events.txt", "hello\n");
is($rc, 1, 'first write returns 1 (published)');

open my $fh, '<', "$dir/events.txt" or die "open: $!";
is(do { local $/; <$fh> }, "hello\n", 'content correct');
close $fh;

# Second write: existing-file-wins, original content preserved.
my $rc2 = write_artifact_atomic("$dir/events.txt", "different\n");
is($rc2, 0, 'second write returns 0 (existing wins)');

open my $fh2, '<', "$dir/events.txt" or die "open: $!";
is(do { local $/; <$fh2> }, "hello\n", 'original content preserved after race loss');
close $fh2;

# Compression-visible filename: helper just uses whatever name caller passes.
my $rc3 = write_artifact_atomic("$dir/events.txt.zst", "compressed-bytes");
is($rc3, 1, 'zst write succeeds');
ok(-e "$dir/events.txt.zst", 'file at compression-visible path');

# Large bytes: exercise the full-write loop (syswrite short-write path).
my $big = "x" x (1024 * 1024);
my $rc4 = write_artifact_atomic("$dir/big.bin", $big);
is($rc4, 1, 'large write published');
ok(-e "$dir/big.bin", 'large file exists');
is(-s "$dir/big.bin", length($big), 'large file size matches');

# No leftover .tmp files after any of the above writes.
opendir(my $dh, $dir) or die "opendir: $!";
my @leftover = grep { /^\.tmp\./ } readdir($dh);
closedir $dh;
is(\@leftover, [], 'no leftover tmp files');

done_testing;
