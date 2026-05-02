use Test2::V0;

# When a test declares HARNESS-JOB-SLOTS larger than the per-job cap
# the user passed (-j N:M / -x M), the job-limiter must report the
# resource as permanently unsatisfiable for THAT test. The scheduler
# then routes the job through an unavailable-action skip_all so:
#  - the user sees a real skip event with a reason,
#  - the run finalizes (no hang waiting on a job that can never run),
#  - other tests that fit the cap continue to use the resource.

use File::Spec ();

BEGIN {
    @INC = map { File::Spec->rel2abs($_) } @INC;
    $ENV{PERL5LIB} = join(
        ':',
        (grep { !ref } @INC),
        (defined $ENV{PERL5LIB} ? ($ENV{PERL5LIB}) : ()),
    );
}

use File::Temp qw/tempdir/;
use Cwd qw/getcwd/;

chomp(my $bin = `sh -c 'command -v yath'`);
skip_all "yath binary not on PATH" unless $bin && -x $bin;

# When this test is itself running inside a yath job, spawning a
# fresh inner yath collides with the outer harness's IPC/TMPDIR
# state and the inner run cannot finalize. Standalone invocation
# (perl -Ilib t/AI/.../this.t) works fine. Skip rather than emit a
# misleading failure.
skip_all "cannot reliably spawn nested yath inside an outer yath job"
    if $ENV{YATH_SCRIPT} || $ENV{T2_HARNESS_INCLUDES};

my $tmp = tempdir(CLEANUP => 1);

# A normal one-slot test (uses default min/max).
my $t1 = "$tmp/one.t";
open my $fh1, '>', $t1 or die "open $t1: $!";
print $fh1 "use Test2::V0; ok(1, 'one slot'); done_testing;\n";
close $fh1;

# A wide test asking for 8 slots via the HARNESS-JOB-SLOTS header.
my $t8 = "$tmp/eight.t";
open my $fh8, '>', $t8 or die "open $t8: $!";
print $fh8 "# HARNESS-JOB-SLOTS 8\nuse Test2::V0; ok(1, 'eight slots'); done_testing;\n";
close $fh8;

sub run_yath {
    my (@args) = @_;
    my $cwd = getcwd();
    # -v so the renderer emits SKIP ALL info lines (Default renderer
    # suppresses them in non-verbose mode even when the underlying
    # event was generated). This test inspects rendered text.
    my $cmd = join ' ', $bin, '-D', 'test', '-v', @args, $t1, $t8, '2>&1';
    my $out = `cd $cwd && AUTHOR_TESTING=1 $cmd`;
    return ($?, $out);
}

subtest '-j 16:8 (cap large enough): both tests run normally' => sub {
    my ($rc, $out) = run_yath('-j16:8');
    is($rc, 0, 'exit 0');
    like($out, qr/Result: PASSED/, 'run passed');
    unlike($out, qr/SKIP ALL/, 'no skip events');
};

subtest '-j 16:4 (cap below T8): T8 skipped with reason, T1 still runs, run finalizes' => sub {
    my ($rc, $out) = run_yath('-j16:4');
    is($rc, 0, 'exit 0 -- skipped tests are not failures');
    like($out, qr/Result: PASSED/,               'run finalizes (did not hang)');
    like($out, qr/SKIP ALL.*Missing resources/i, 'T8 reported as skip with missing-resource reason');
    like($out, qr/jobcount/,                     'reason mentions the jobcount resource');
};

subtest 'only-unsatisfiable: every test exceeds cap, run still finalizes' => sub {
    my $cwd = getcwd();
    my $out = `cd $cwd && AUTHOR_TESTING=1 $bin -D test -v -j16:4 $t8 2>&1`;
    my $rc  = $?;
    is($rc, 0, 'exit 0');
    like($out, qr/Result: PASSED/,               'run finalizes even when all tests skip');
    like($out, qr/SKIP ALL.*Missing resources/i, 'skip event with reason');
};

# Phase 8 default: the archive lands in tempdir, not cwd, so there
# should normally be nothing to remove here. Keep the glob-and-unlink
# defensively in case an older yath binary on PATH still drops the
# archive into cwd.
unlink for glob '*.yath';

done_testing;
