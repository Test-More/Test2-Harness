use strict;
use warnings;

# This test runs the test suite as a subprocess and fails if the run
# leaves behind any filesystem artifacts (new untracked files, modified
# tracked files) that weren't present beforehand. It is tolerant of
# pre-existing uncommitted work: only state that *changed* during the
# run is treated as cruft.
#
# Motivation: a bug in t/lib/Test2/Harness2/Test/Loggers.pm once left a
# literal `%LOG_DIR%/` directory in the repo root because logger specs
# used placeholder tokens ('%LOG_DIR%/%JOB_TRY%.jsonl') that nothing
# ever substituted. The tokens landed on disk verbatim. This test
# guards the repo against regressions of that class of bug.

use Test2::V0;
use Test2::Require::AuthorTesting;

use File::Spec();
use Cwd qw/abs_path/;

# Require a real git working tree -- the detection strategy below leans
# entirely on `git status --porcelain`, so without git we can't tell
# cruft from legitimately-uncommitted developer state.
my $in_git = do {
    local $ENV{LC_ALL} = 'C';
    my $out = `git rev-parse --is-inside-work-tree 2>/dev/null`;
    chomp $out;
    $out eq 'true';
};
skip_all "not inside a git working tree" unless $in_git;

my $repo_root = do {
    chomp(my $r = `git rev-parse --show-toplevel`);
    $r;
};
skip_all "could not determine repo root" unless $repo_root && -d $repo_root;

# Snapshot the dirty-state porcelain before the run. Each line is a
# two-char status code + ' ' + path (may be quoted). We don't parse it
# beyond "line as string" -- set membership is enough to tell new-vs-
# pre-existing.
#
# --untracked-files=all so new files inside untracked directories show
# up individually; --ignored=no so gitignored artifacts (build outputs,
# local/, etc.) are correctly excluded -- those are expected cruft the
# developer opted into, not test-run cruft.
sub porcelain_snapshot {
    local $ENV{LC_ALL} = 'C';
    my $out = `git -C '$repo_root' status --porcelain=v1 --untracked-files=all --ignored=no 2>&1`;
    my %set;
    for my $line (split /\n/, $out) {
        next unless length $line;
        $set{$line} = 1;
    }
    return \%set;
}

my $before = porcelain_snapshot();

# Drive the suite via test.pl so we exercise the exact path `make test`
# runs. We intentionally don't assert on the exit status -- individual
# test failures are a separate concern, and we want the artifact check
# to run regardless of whether the suite happens to be green today.
my $test_pl = File::Spec->catfile($repo_root, 'test.pl');
skip_all "test.pl not found at $test_pl" unless -f $test_pl;

# Use the same perl this process is running under so the subprocess
# sees the same @INC / installed dists.
my @cmd = ($^X, '-I' . File::Spec->catdir($repo_root, 'lib'), $test_pl);

# Run with repo root as cwd so any stray cwd-relative writes land there
# (where porcelain_snapshot will see them), not in wherever t2-harness
# decided to chdir while driving its own sub-tests.
chdir $repo_root or die "chdir $repo_root: $!";

# Capture output so we don't flood the AuthorTesting log when nested
# failures happen; the exit-status / per-test detail is the subsystem's
# own business for this test.
my $rc = system(@cmd);
note "test.pl exited with rc=$rc" if $rc;

my $after = porcelain_snapshot();

# Anything that appears in `after` but not `before` is new cruft
# introduced by the run. Conversely, anything present in both is
# pre-existing and ignored.
my @new = sort grep { !$before->{$_} } keys %$after;

is(
    \@new,
    [],
    "test run left no new tracked modifications or untracked files behind",
) or diag(
    "New porcelain entries after the test run:\n  " . join("\n  ", @new)
);

done_testing;
