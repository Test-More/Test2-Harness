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

use Test2::Util qw/CAN_REALLY_FORK/;
skip_all "Cannot fork, skipping reload test"
    unless CAN_REALLY_FORK;
skip_all "Skip reload tests under AUTOMATED_TESTING (timing-sensitive)"
    if $ENV{AUTOMATED_TESTING};

# Port of reference/legacy/t/integration/reload_syntax_error.t,
# simplified for the non-staged preload subsystem. Original goal:
# verify that a persistent daemon survives a broken-then-fixed cycle
# on a preloaded module and that the eventual fix reaches subsequent
# `yath run` invocations.
#
# Steps:
#   1. Start the daemon with --reloader=mstat and a valid Preload.
#   2. Queue a baseline run; assert pass.
#   3. Rewrite the preload with a syntax error, bump mtime. The
#      daemon stays up (the reloader records last_error but does
#      not exit).
#   4. Rewrite the preload back to a valid module with a different
#      value, bump mtime; queue another run and assert the post-fix
#      value reaches it.
#   5. Stop the daemon.

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print $fh $content;
    close $fh;
}

my $orig_cwd = getcwd;
my $tmp      = tempdir(CLEANUP => 1);

write_file("$tmp/.yath.rc", '');
make_path("$tmp/lib");

write_file("$tmp/lib/Preload.pm", <<'EOM');
package Preload;
use strict; use warnings;
our $VAR = 'initial';
1;
EOM

my $tf_initial = "$tmp/initial.t";
write_file($tf_initial, <<'EOT');
use Test2::V0;
require Preload;
is($Preload::VAR, 'initial', 'Preload::VAR is "initial" (baseline)');
done_testing;
EOT

my $tf_fixed = "$tmp/fixed.t";
write_file($tf_fixed, <<'EOT');
use Test2::V0;
require Preload;
is($Preload::VAR, 'fixed', 'Preload::VAR is "fixed" after recovery');
done_testing;
EOT

chdir $tmp;

yath(
    command => 'start',
    args    => ['-PPreload', '--reloader', 'mstat'],
    pre     => ["-D$tmp/lib"],
    exit    => 0,
    test    => sub {
        yath(
            command => 'run',
            args    => [$tf_initial],
            exit    => 0,
            test    => sub {
                my $out = shift;
                like($out->{output}, qr{^PASS:\s*job\b}m,
                    'baseline run passed (Preload::VAR=initial)');
                unlike($out->{output}, qr/^FAIL:/m, 'no FAIL in baseline run');
            },
        );

        # Let the snapshot tick complete before edits.
        sleep(0.5);

        # Step 3: rewrite with a runtime-bareword that compiles as
        # an indirect-method call and fails at require time. Kept
        # as a single line so the heredoc itself stays valid.
        write_file("$tmp/lib/Preload.pm", <<'EOM');
package Preload;
use strict; use warnings;
this is not perl;
our $VAR = 'after-break';
1;
EOM
        my $t1 = time + 2;
        utime($t1, $t1, "$tmp/lib/Preload.pm") or die "utime: $!";

        # Wait for the reloader to attempt the in-place reload, fail,
        # and emit preload_broken; the daemon must stay alive.
        sleep(2.0);

        # Step 4: rewrite back to a valid module with the recovered
        # value. The reloader's failure path restored the %INC
        # entries so the next tick still sees the file as a
        # candidate and re-tries the require.
        write_file("$tmp/lib/Preload.pm", <<'EOM');
package Preload;
use strict; use warnings;
our $VAR = 'fixed';
1;
EOM
        my $t2 = time + 4;
        utime($t2, $t2, "$tmp/lib/Preload.pm") or die "utime: $!";

        # Wait for preload_ready re-fire.
        sleep(2.0);

        yath(
            command => 'run',
            args    => [$tf_fixed],
            exit    => 0,
            test    => sub {
                my $out = shift;
                like($out->{output}, qr{^PASS:\s*job\b}m,
                    'recovered run passed (Preload::VAR=fixed)');
                unlike($out->{output}, qr/^FAIL:/m, 'no FAIL in recovered run');
            },
        );

        yath(command => 'stop', exit => 0);
    },
);

chdir $orig_cwd;

done_testing;
