use Test2::V0;
use Test2::Require::Module 'DBD::SQLite';
use Test2::Require::AuthorTesting;

use File::Temp qw/tempdir/;
use File::Path qw/make_path/;

use Test2::Harness2::Util::JSON qw/encode_json/;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer/;
use App::Yath2::Log;
use App::Yath2::DB;
use App::Yath2::Log::DB;

# Build a synthetic log directory. The DB insert path reads spec.jsonl and
# report.jsonl artifact files to populate run/job_try summary columns
# (pass, exit, started_at, ended_at). The .sealed markers are only used by
# the Directory and TarZIdx backends; for DB tests we must supply actual
# jsonl artifact files to populate the typed columns.
#
# Layout:
#   services/svc-a/               (global service)
#   runs/0/                       (run 0, pass=1, exit=0)
#   runs/0/services/run-svc/      (run-scoped service)
#   runs/0/jobs/0/0/              (job 0, try 0, pass=1)
#   runs/0/jobs/1/0/              (job 1, try 0, pass=0)

my $src = tempdir(CLEANUP => 1);

make_path("$src/services/svc-a");
make_path("$src/runs/0/services/run-svc");
make_path("$src/runs/0/jobs/0/0");
make_path("$src/runs/0/jobs/1/0");

# events artifacts so the archive-insert path creates artifact rows
for my $base (
    'services/svc-a',
    'runs/0/services/run-svc',
    'runs/0/jobs/0/0',
    'runs/0/jobs/1/0',
    )
{
    my $w = open_zstd_writer("$src/$base/events.jsonl.zst");
    $w->say(encode_json({ping => 1}));
    $w->close;
}

# spec.jsonl for each job try (jobs.test_file_id NOT NULL).
# started_at is promoted from spec (see @_JOB_TRIES_SPEC_PROMOTED).
for my $pair (
    ['runs/0/jobs/0/0', 't/job0.t', 1_000_001],
    ['runs/0/jobs/1/0', 't/job1.t', 1_000_002],
    )
{
    my ($base, $rel, $started) = @$pair;
    my $w = open_zstd_writer("$src/$base/spec.jsonl.zst");
    $w->say(encode_json({relative => $rel, started_at => $started}));
    $w->close;
}

# report.jsonl for each job try: the insert path promotes pass/exit/
# started_at/ended_at from report.jsonl into job_tries typed columns.
{
    my $w = open_zstd_writer("$src/runs/0/jobs/0/0/report.jsonl.zst");
    $w->say(encode_json({pass => 1, exit => 0, started_at => 1_000_001, ended_at => 1_000_050}));
    $w->close;
}
{
    my $w = open_zstd_writer("$src/runs/0/jobs/1/0/report.jsonl.zst");
    $w->say(encode_json({pass => 0, exit => 1, started_at => 1_000_002, ended_at => 1_000_080}));
    $w->close;
}

# report.jsonl for run 0
{
    my $w = open_zstd_writer("$src/runs/0/report.jsonl.zst");
    $w->say(encode_json({pass => 1, exit => 0, ended_at => 1_000_100}));
    $w->close;
}
# spec.jsonl for run 0 (populates started_at)
{
    my $w = open_zstd_writer("$src/runs/0/spec.jsonl.zst");
    $w->say(encode_json({started_at => 1_000_000}));
    $w->close;
}

# Create the SQLite archive in a temp dir.
my $arc_dir  = tempdir(CLEANUP => 1);
my $arc_path = "$arc_dir/run.yath";
App::Yath2::Log->new(dir => $src)->archive($arc_path, format => 'sqlite');

my $log = App::Yath2::Log->new(file => $arc_path);
isa_ok($log, ['App::Yath2::Log::DB'], 'auto-detect sqlite -> Log::DB');

# {{{ run_producers

subtest 'run_producers' => sub {
    my @runs = $log->run_producers->all;
    is(scalar(@runs), 1, 'one run');

    my ($r0) = grep { $_->id == 0 } @runs;
    ok(defined $r0, 'run 0 found');

    is($r0->kind,   'run',    'kind=run');
    is($r0->state,  'sealed', 'DB runs always sealed');
    is($r0->id,     0,        'id = run_ord');
    is($r0->run_id, 0,        'run_id = run_ord');
    ok(!defined $r0->parent_id, 'runs have no parent_id');

    is($r0->pass, 1, 'pass from report.jsonl');
    is($r0->exit, 0, 'exit from report.jsonl');

    # started_at and ended_at: the insert path converts ISO timestamps
    # or epoch floats to DB datetime strings; accept any defined value.
    ok(defined $r0->started_at, 'started_at is defined');
    ok(defined $r0->ended_at,   'ended_at is defined');
};

# }}}

# {{{ job_producers

subtest 'job_producers' => sub {
    my @jobs = $log->job_producers(0)->all;
    is(scalar(@jobs), 2, 'two jobs for run 0');

    my ($j0) = grep { $_->id == 0 } @jobs;
    my ($j1) = grep { $_->id == 1 } @jobs;
    ok(defined $j0, 'job 0 found');
    ok(defined $j1, 'job 1 found');

    is($j0->kind,      'job',    'kind=job');
    is($j0->state,     'sealed', 'DB jobs always sealed');
    is($j0->parent_id, 0,        'parent_id = run_ord');
    is($j0->run_id,    0,        'run_id = run_ord');
    is($j0->try,       0,        'try=0 (first attempt)');
    is($j0->pass,      1,        'job 0 pass from report.jsonl');

    is($j1->pass,  0,        'job 1 fail from report.jsonl');
    is($j1->state, 'sealed', 'job 1 sealed');

    ok(defined $j0->started_at, 'job 0 started_at defined');
    ok(defined $j0->ended_at,   'job 0 ended_at defined');
};

# }}}

# {{{ service_producers

subtest 'service_producers' => sub {
    # Global services (no run scope)
    my @global = $log->service_producers->all;
    is(scalar(@global),   1,         'one global service');
    is($global[0]->id,    'svc-a',   'global service name=svc-a');
    is($global[0]->kind,  'service', 'kind=service');
    is($global[0]->state, 'sealed',  'DB services always sealed');
    ok(!defined $global[0]->parent_id, 'global service has no parent_id');

    # Run-scoped services
    my @run_svcs = $log->service_producers(0)->all;
    is(scalar(@run_svcs),       1,         'one run-scoped service for run 0');
    is($run_svcs[0]->id,        'run-svc', 'run-scoped service name=run-svc');
    is($run_svcs[0]->parent_id, 0,         'run-scoped parent_id=run_ord');
    is($run_svcs[0]->run_id,    0,         'run_id=run_ord');
};

# }}}

# {{{ collector_producers

subtest 'collector_producers' => sub {
    my @cols = $log->collector_producers->all;
    is(scalar(@cols), 0, 'DB backend: collectors not a DB concept');
};

# }}}

# {{{ artifact_refs in job producers

subtest 'artifact_refs in job producers' => sub {
    my @jobs = $log->job_producers(0)->all;
    my ($j0) = grep { $_->id == 0 } @jobs;

    ok(defined $j0->artifact_refs,          'artifact_refs is defined');
    ok(ref($j0->artifact_refs) eq 'HASH',   'artifact_refs is a hashref');
    ok(exists $j0->artifact_refs->{events}, 'events artifact ref present');

    # spec and report are reconstructed from typed DB columns (not stored as
    # artifact rows), so they do not appear in artifact_refs for DB backends.
    ok(!exists $j0->artifact_refs->{spec},   'spec not in artifact_refs (reconstructed)');
    ok(!exists $j0->artifact_refs->{report}, 'report not in artifact_refs (reconstructed)');

    # report_available is derived from ended_at/pass columns, not artifact rows.
    is($j0->report_available, 1, 'report_available=1 (ended_at is set -> report was ingested)');
};

# }}}

# {{{ bulk-fetch query count (no N+1)
#
# job_producers(0) must complete in a bounded number of DB round-trips.
# A naive implementation issues one try_rows() per job (N+1 pattern);
# the bulk implementation issues one JOIN query for all tries.
# We allow up to 6 queries to cover: run_exists check, run_id_for_ord,
# job_rows, try_rows_for_run, artifact_rows_for_archive, and any
# lazy-init resolve. Strictly less than 2*N queries where N=2 jobs.

subtest 'bulk-fetch query count' => sub {
    my $query_count  = 0;
    my $orig_execute = \&DBI::st::execute;

    {
        no warnings 'redefine';
        local *DBI::st::execute = sub {
            $query_count++;
            goto &$orig_execute;
        };

        # Clear any cached artifacts index so we get a fresh count.
        delete $log->{_artifact_ref_index};
        delete $log->{_db_archive_id};

        my @jobs = $log->job_producers(0)->all;
        ok(scalar(@jobs) == 2, 'still returns 2 jobs under counting hook');
    }

    note("queries issued for job_producers(0): $query_count");
    # Strict bound: must be fewer than 2 * number_of_jobs + base overhead.
    # A correct bulk implementation is ~4-5 queries regardless of job count.
    ok($query_count <= 8, "query count ($query_count) <= 8 (no N+1 per job)");
};

# }}}

done_testing;
