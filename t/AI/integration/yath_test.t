use v5.38;
use Test2::V0;
use File::Temp qw/tempdir/;
use Cwd qw/abs_path/;
use POSIX ();

# Convert any relative @INC entries to absolute paths before loading
# App::Yath2::Command::test (which will trigger lazy-requires that need @INC
# to remain valid after a chdir).  Skip code-refs (@INC hooks) — those are
# not file paths and must be left untouched.
BEGIN { @INC = map { ref($_) ? $_ : (abs_path($_) // $_) } @INC }

use App::Yath2::Command::test;

my $orig = abs_path('.');
my $pass = "$orig/t/AI/scripts/pass.tx";
my $fail = "$orig/t/AI/scripts/fail.tx";

ok(-f $pass, "pass fixture exists");
ok(-f $fail, "fail fixture exists");

# Run the command inside an isolated dir so the sqlite file lands there.
# Each call is wrapped in a fork so the global DBIx::QuickORM ORM singleton
# is always fresh — the singleton stores one db path per process, so
# re-using it across calls to run_yath_test within the same process would
# silently reuse the first call's (deleted) database.
# Capture stdout via a real temp file so child processes (forked by the
# collector) inherit a valid fd for STDOUT — an in-memory scalar ref has no
# real fd, which breaks swap_io in the collector child.
sub run_yath_test (@files) {
    my $dir      = tempdir(CLEANUP => 1);
    my $cap_path = "$dir/stdout.txt";

    my $pid = fork // die "fork for run_yath_test: $!";
    if ($pid == 0) {
        my $child_exit = 1;
        my $ok = eval {
            chdir $dir or die "chdir $dir: $!";
            open(my $cap_fh, '>', $cap_path) or die "open cap: $!";
            open(my $old_stdout, '>&', \*STDOUT) or die "dup STDOUT: $!";
            open(STDOUT, '>&', $cap_fh)          or die "redirect STDOUT: $!";
            STDOUT->autoflush(1);
            my $cmd = App::Yath2::Command::test->new(argv => [@files]);
            $child_exit = $cmd->run;
            1;
        };
        warn "run_yath_test child: $@\n" unless $ok;
        POSIX::_exit($ok ? $child_exit : 255);
    }

    waitpid($pid, 0);
    my $status = $?;
    my $exit   = ($status >> 8) & 0xFF;

    my $out = '';
    if (-f $cap_path) {
        open my $rfh, '<', $cap_path or die "read cap: $!";
        $out = do { local $/; <$rfh> };
    }

    return ($exit, $out);
}

# All-pass run.
my ($exit1, $out1) = run_yath_test($pass);
is($exit1, 0, "all-pass run exits 0");
like($out1, qr/PASS\s+\Q$pass\E/, "printed PASS for the passing test");
unlike($out1, qr/FAIL/, "no FAIL line in an all-pass run");

# Mixed run: one pass, one fail -> non-zero exit.
my ($exit2, $out2) = run_yath_test($pass, $fail);
is($exit2, 1, "run with a failing test exits non-zero");
like($out2, qr/PASS\s+\Q$pass\E/, "printed PASS for the passing test");
like($out2, qr/FAIL\s+\Q$fail\E/, "printed FAIL for the failing test");

done_testing;
