use Test2::V0;

use File::Temp qw/tempdir/;
use Time::HiRes qw/time sleep/;

use lib 't/lib';
use Test2::Harness2;
use Test2::Harness2::TestFile;
use Test2::Harness2::Test::Loggers qw/classic_harness_loggers classic_test_loggers/;
use Test2::Harness2::Test::SpawnRace qw/finish_and_wait/;

sub wait_until {
    my ($check, $timeout_sec) = @_;
    my $deadline = time + $timeout_sec;
    while (time < $deadline) {
        return 1 if $check->();
        sleep(0.05);
    }
    return 0;
}

# Phase 4 on-disk layout: per-run files live under
# logs/runs/<run_id>/, with three well-known siblings:
#
#   spec.json[.zst]    -- immutable run spec (Run->TO_JSON), one-shot
#                         write at run start.
#   state.json[.zst]   -- mutable run state (Run::State->TO_JSON),
#                         atomically replaced as the run advances.
#   events.jsonl[.zst] -- the run service collector's JSONL event
#                         stream.
#
# All three must exist for any consumer (replay, archive, extract,
# the static streamer) to accept the run; the LogArchive layer
# rejects pre-Phase-4 layouts (runs/<id>.json or runs/<id>.jsonl)
# with a clear error.

my $dir = tempdir(CLEANUP => 1);

my $tf_path = "$dir/ok.t";
open my $fh, '>', $tf_path or die $!;
print $fh "use Test2::V0; ok(1); done_testing;\n";
close $fh;

my $spawn = Test2::Harness2->spawn(
    workdir         => $dir,
    loggers         => classic_harness_loggers($dir),
    service_loggers => [
        'Test2::Harness2::Collector::Logger::JSONL',
        'Test2::Harness2::Collector::Logger::JSON',
    ],
    test_loggers => classic_test_loggers(),
);

my $q = $spawn->queue_test_run(files => [Test2::Harness2::TestFile->new(file => $tf_path)]);
ok($q->{ok}, 'queued') or diag explain $q;

wait_until(
    sub {
        my $s = $spawn->status;
        return !@{$s->{queue}} && !@{$s->{running} // []};
    },
    15,
) or die "run did not drain";

finish_and_wait($spawn);

# Inspect logs/runs/<run_id>/.
opendir my $rdh, "$dir/logs/runs" or die "open $dir/logs/runs: $!";
my @run_dirs = grep { !/^\./ && -d "$dir/logs/runs/$_" } readdir $rdh;
closedir $rdh;

is(scalar @run_dirs, 1, 'exactly one run directory under logs/runs/');
my $run_id = $run_dirs[0];
my $rundir = "$dir/logs/runs/$run_id";

# spec.json -- always written.
ok(
    -e "$rundir/spec.json.zst" || -e "$rundir/spec.json",
    'spec.json (or .json.zst) exists alongside the run dir'
);

# state.json -- written by the JSON logger as the run mutates.
ok(
    -e "$rundir/state.json.zst" || -e "$rundir/state.json",
    'state.json (or .json.zst) exists alongside the run dir'
);

# events.jsonl -- written by the JSONL logger across the run.
ok(
    -e "$rundir/events.jsonl.zst" || -e "$rundir/events.jsonl",
    'events.jsonl (or .jsonl.zst) exists alongside the run dir'
);

# The legacy paths (runs/<id>.json, runs/<id>.jsonl) must NOT be present.
ok(!-e "$dir/logs/runs/$run_id.json",      'no legacy runs/<run_id>.json sibling');
ok(!-e "$dir/logs/runs/$run_id.jsonl",     'no legacy runs/<run_id>.jsonl sibling');
ok(!-e "$dir/logs/runs/$run_id.json.zst",  'no legacy runs/<run_id>.json.zst sibling');
ok(!-e "$dir/logs/runs/$run_id.jsonl.zst", 'no legacy runs/<run_id>.jsonl.zst sibling');

done_testing;
