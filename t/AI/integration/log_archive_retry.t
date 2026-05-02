use Test2::V0;

# Phase 4.5 retry layout: instantiate the JSONL logger twice for the
# same job_id with different job_try values. Both must land at
# distinct on-disk paths under runs/<run>/tests/<job>/<try>.jsonl
# (compressed by default). Pre-Phase-4.5 the basename was
# runs/<run>/tests/<job>.jsonl, so a retry would clobber the first
# try's content; this test fails on the legacy layout.

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector::Logger::JSONL;
use Test2::Harness2::Collector::Logger::JSON;

my $logdir = tempdir(CLEANUP => 1);

sub make_jsonl_logger {
    my (%info) = @_;
    my $logger = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {peer => 'fake'},
    );
    $logger->set_process_info(
        logdir  => $logdir,
        run_id  => 'R',
        job_id  => 'J',
        %info,
    );
    return $logger;
}

# Try 0.
my $first = make_jsonl_logger(job_try => 0);
my @paths_first = $first->output_files;
$first->prepare_output_locations;
$first->startup;
# Force the writer through one event so the file has bytes (autoflush).
ok(scalar(@paths_first), 'try-0 logger reported an output file');
my $first_path = $paths_first[0];
like(
    $first_path,
    qr{^\Q$logdir\E/runs/R/tests/J/0\.jsonl},
    'try 0 path is runs/R/tests/J/0.jsonl[.zst]',
);
$first->shutdown;

ok(-e $first_path,            'try 0 file exists after shutdown');
ok(-d "$logdir/runs/R/tests/J", 'tests/J/ is a directory (per-job dir)');

# Capture try-0 size before try-1 starts.
my $first_size = -s $first_path;

# Try 1: same job_id, job_try=1. The basename rule must produce a
# distinct file so try 1 cannot clobber try 0.
my $second = make_jsonl_logger(job_try => 1);
my @paths_second = $second->output_files;
$second->prepare_output_locations;
$second->startup;
my $second_path = $paths_second[0];
like(
    $second_path,
    qr{^\Q$logdir\E/runs/R/tests/J/1\.jsonl},
    'try 1 path is runs/R/tests/J/1.jsonl[.zst]',
);
isnt($first_path, $second_path, 'try 0 and try 1 paths differ');
$second->shutdown;

ok(-e $first_path,  'try 0 file still exists after try 1 shutdown');
ok(-e $second_path, 'try 1 file exists after shutdown');

# Confirm the legacy clobber path was NOT created.
ok(
    !-e "$logdir/runs/R/tests/J.jsonl"
        && !-e "$logdir/runs/R/tests/J.jsonl.zst",
    'no legacy per-job basename (no clobber-prone shape)',
);

# Confirm try 0's file did not change between try 1's startup and
# shutdown -- it was untouched. Pre-fix this would fail because both
# tries opened the same path.
is(-s $first_path, $first_size, 'try 0 file size unchanged after try 1 ran');

done_testing;
