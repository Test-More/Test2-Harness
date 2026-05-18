# HARNESS2: conflicts yath
# HARNESS2: duration long
use Test2::V0;
use Test2::Require::AuthorTesting;

use Cwd qw/getcwd/;
use File::Path qw/make_path/;
use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use lib 't/lib';
use Test2::Harness2::Test::Yath qw/yath/;

# Port of reference/legacy/t/integration/reload.t, simplified for the
# non-staged preload subsystem. Original verified a sequence of
# reloader log messages emitted by stage-based "blacklisting" /
# "in-place" reloaders; that machinery no longer exists. What
# survives is the user-visible contract:
#
#   * a daemon started with --reloader=mstat picks up edits to a
#     preloaded module while it stays running;
#   * a test routed through that preload, queued via `yath run`
#     after the edit, sees the post-edit code.
#
# The recovery cycle (broken -> fixed) lives in
# t/AI/integration/reload_syntax_error.t. Both backends share the
# same plumbing; this test exercises HiResStat because INotify needs
# Linux::Inotify2 which may not be installed on every reviewer's
# box.

skip_all "Skip reload tests under AUTOMATED_TESTING (timing-sensitive)"
    if $ENV{AUTOMATED_TESTING};

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print $fh $content;
    close $fh;
}

my $orig_cwd = getcwd;
my $tmp      = tempdir(CLEANUP => 1);

# Plant .yath.rc so Reloader::Common::_project_root() walking up from
# the daemon's cwd anchors to $tmp -- otherwise the reloader scans
# the entire test2-harness repo each tick.
write_file("$tmp/.yath.rc", '');

make_path("$tmp/lib");
write_file("$tmp/lib/Preload.pm", <<'EOM');
package Preload;
use strict; use warnings;
sub greet { 'before' }
1;
EOM

my $tf_before = "$tmp/before.t";
write_file($tf_before, <<'EOT');
use Test2::V0;
require Preload;
is(Preload::greet(), 'before', 'Preload::greet returns "before"');
done_testing;
EOT

my $tf_after = "$tmp/after.t";
write_file($tf_after, <<'EOT');
use Test2::V0;
require Preload;
is(Preload::greet(), 'after', 'Preload::greet returns "after" after reload');
done_testing;
EOT

# Move cwd into the tempdir so the daemon (and the preload service
# it forks) inherit it, which is how the reloader anchors its
# project_root.
chdir $tmp;

yath(
    command => 'start',
    args    => ['-PPreload', '--reloader', 'mstat'],
    pre     => ["-D$tmp/lib"],
    exit    => 0,
    test    => sub {
        yath(
            command => 'run',
            args    => [$tf_before],
            exit    => 0,
            test    => sub {
                my $out = shift;
                like($out->{output}, qr{^PASS:\s*job\b}m,
                    'baseline run passed (Preload::greet=before)');
                unlike($out->{output}, qr/^FAIL:/m, 'no FAIL in baseline run');
            },
        );

        # HiResStat's first tick is a pure mtime snapshot. We must
        # let that snapshot land before rewriting; otherwise the
        # corrupted mtime becomes the baseline and no reload fires.
        sleep(0.5);

        write_file("$tmp/lib/Preload.pm", <<'EOM');
package Preload;
use strict; use warnings;
sub greet { 'after' }
1;
EOM
        my $now = time + 2;
        utime($now, $now, "$tmp/lib/Preload.pm") or die "utime: $!";

        # Wait through several poll cycles (default 0.25s) plus an
        # IPC round-trip cushion.
        sleep(2.0);

        yath(
            command => 'run',
            args    => [$tf_after],
            exit    => 0,
            test    => sub {
                my $out = shift;
                like($out->{output}, qr{^PASS:\s*job\b}m,
                    'post-reload run passed (Preload::greet=after)');
                unlike($out->{output}, qr/^FAIL:/m, 'no FAIL in post-reload run');
            },
        );

        yath(command => 'stop', exit => 0);
    },
);

chdir $orig_cwd;

done_testing;
