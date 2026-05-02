use Test2::V0;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use App::Yath2::LogArchive;
use Test2::Harness2::Util::JSON qw/write_json_zst_file_atomic/;

my $dir = tempdir(CLEANUP => 1);
make_path("$dir/services/harness");
make_path("$dir/runs/R1/services/run");
make_path("$dir/runs/R1/tests/J1");
make_path("$dir/runs/R1/tests/J2");
make_path("$dir/runs/R2");

# Stub artifact files. Per-service-directory layout: each service
# (global or run-scoped) lives under its own per-name directory and
# carries one file per logger leaf. Contents stay empty/zero -- they
# are only used to confirm existence and the extension -> logger-class
# lookup (LogArchive derives the producing logger from the on-disk
# extension, no manifest needed).
open my $fh, '>', "$dir/services/harness/events.jsonl.zst" or die $!; close $fh;
open $fh,    '>', "$dir/services/harness/state.json.zst"   or die $!; close $fh;
open $fh,    '>', "$dir/runs/R1/services/run/events.jsonl.zst" or die $!; close $fh;
open $fh,    '>', "$dir/runs/R1/tests/J1/0.jsonl.zst"          or die $!; close $fh;

# R1 has a spec.json + artifacts; R2 is an empty directory; J1 has
# an artifact, J2 is an empty directory. All four (R1, R2, J1, J2)
# should be reported -- existence is keyed on directory presence,
# not on any marker file.
write_json_zst_file_atomic(
    "$dir/runs/R1/spec.json.zst",
    {run_id => 'R1', created_at => 1, jobs => []},
);

my $la = App::Yath2::LogArchive->open(path => $dir);
isa_ok($la, 'App::Yath2::LogArchive::Directory');

is(
    $la->artifacts,
    {
        append  => {
            'services/harness/events' => ['services/harness/events.jsonl.zst'],
        },
        replace => {
            'services/harness/state'  => ['services/harness/state.json.zst'],
        },
    },
    'global artifacts (append/replace shape, per-service-dir layout)',
);

is(
    $la->artifacts('R1'),
    {
        append  => {
            'services/run/events' => ['runs/R1/services/run/events.jsonl.zst'],
        },
        replace => {
            spec => ['runs/R1/spec.json.zst'],
        },
    },
    'run-scoped artifacts (append/replace shape, drops tests/* entries)',
);

is(
    $la->artifacts('R1', 'J1'),
    {
        append  => { 0 => ['runs/R1/tests/J1/0.jsonl.zst'] },
        replace => {},
    },
    'job-scoped artifacts keyed by try',
);

is([sort $la->runs], ['R1', 'R2'], 'runs() reports every runs/<id>/ directory');

is([sort $la->jobs('R1')], ['J1', 'J2'], 'jobs(R1) reports every tests/<id>/ directory');

is([sort $la->services],       ['harness'], 'global services from services/<name>/ directory');
is([sort $la->services('R1')], ['run'],     'run-scoped services from runs/<run>/services/<name>/ directory');

done_testing;
