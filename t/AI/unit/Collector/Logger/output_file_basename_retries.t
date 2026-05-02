use Test2::V0;

# Phase 4.5: per-job test logs land in a per-job directory with a
# per-try basename so multiple tries of the same job do not clobber
# each other. This test asserts the role-computed basename is
# retry-aware, and that two distinct tries produce two distinct files
# under the same job directory.

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

# Build a minimal logger consuming the role and exercise the
# basename-derivation rule directly. We do not need a live collector
# for this check.
{
    package T2H2_RetryLayout_Logger;
    use Object::HashBase qw{
        <logdir
        <run_id
        <job_id
        <job_try
    };
    use Role::Tiny::With;
    sub update_type  { 'append' }
    sub file_ext     { 'jsonl' }
    sub log_reader   { undef }
    sub ready        { 0 }
    sub fetch_events { () }
    sub fetch_state  { undef }
    with 'Test2::Harness2::Role::Collector::Logger';
}

my $logdir = tempdir(CLEANUP => 1);

my $first = T2H2_RetryLayout_Logger->new(
    logdir  => $logdir,
    run_id  => 'R',
    job_id  => 'J',
    job_try => 0,
);

my $second = T2H2_RetryLayout_Logger->new(
    logdir  => $logdir,
    run_id  => 'R',
    job_id  => 'J',
    job_try => 1,
);

is(
    $first->output_file_basename,
    "$logdir/runs/R/tests/J/0",
    'try 0 basename: runs/<run>/tests/<job>/0',
);
is(
    $second->output_file_basename,
    "$logdir/runs/R/tests/J/1",
    'try 1 basename: runs/<run>/tests/<job>/1',
);

# Materialise both as if the logger appended a .jsonl suffix; confirm
# they are distinct paths under one shared per-job directory.
my $f0 = $first->output_file_basename . '.jsonl';
my $f1 = $second->output_file_basename . '.jsonl';

isnt($f0, $f1, 'try 0 and try 1 paths are distinct');
my ($d0) = $f0 =~ m{(.*)/[^/]+\z};
my ($d1) = $f1 =~ m{(.*)/[^/]+\z};
is($d0, $d1, 'both tries share the same per-job directory');

# Pre-create the parent directory and verify both files can be opened
# side by side (i.e. neither write would clobber the other).
make_path($d0);
open(my $fh0, '>', $f0) or die $!;
print $fh0 "try0\n";
close $fh0;
open(my $fh1, '>', $f1) or die $!;
print $fh1 "try1\n";
close $fh1;

ok(-f $f0, 'try 0 file exists');
ok(-f $f1, 'try 1 file exists');

# Re-read the first one to confirm it was not clobbered by the second
# write.
open(my $rfh0, '<', $f0) or die $!;
is(scalar(<$rfh0>), "try0\n", 'try 0 file unmodified after try 1 was written');
close $rfh0;

# job_try is required when job_id is set.
my $missing_try = T2H2_RetryLayout_Logger->new(
    logdir => $logdir,
    run_id => 'R',
    job_id => 'J',
);
like(
    dies { $missing_try->output_file_basename },
    qr/'job_try' is required/,
    'missing job_try croaks',
);

done_testing;
