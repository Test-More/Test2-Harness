use v5.38;
use Test2::V0;
use Test2::Util::UUID qw/gen_uuid/;
use File::Temp qw/tempdir/;
use Test2::Harness2;

my $dir  = tempdir(CLEANUP => 1);
my $path = "$dir/harness.sqlite";

my $h = Test2::Harness2->new(db_path => $path);
isa_ok($h, ['Test2::Harness2'], "constructed harness");

ok(lives { $h->initialize }, "initialize creates the sqlite file + loads DDL") or diag($@);
ok(-s $path, "sqlite file exists and is non-empty");

my $con = $h->connection;
isa_ok($con, ['DBIx::QuickORM::Connection'], "got a connection");

# The schema autofilled: the run table handle is usable.
ok(lives { $con->handle('run') }, "run table handle available");

# --- queue_run + finalize_run ---
# gen_uuid returns uppercase; QuickORM inflates UUIDs to lowercase.
# Normalise upfront so comparisons against ->field() values work.
my $runner_uuid = lc(gen_uuid());
$con->handle('runner')->insert({ runner_uuid => $runner_uuid });
my $account = $con->handle('account')->insert({ email => 'me@example.com' });
my $project = $con->handle('project')->insert({ name => 'proj' });

my $run = $h->queue_run(
    runner_uuid => $runner_uuid,
    account_id  => $account->field('account_id'),
    project_id  => $project->field('project_id'),
    files       => ['t/AI/scripts/pass.tx', 't/AI/scripts/fail.tx'],
);
ok($run, "queue_run returned a run row");
my $run_uuid = $run->field('run_uuid');

is($run->field('runner_uuid'), $runner_uuid, "run linked to runner");
is($run->field('run_uuid_string'), lc($run_uuid),
    "generated run_uuid_string holds the canonical lowercase form (indexed for human lookup)");

my @jobs = $con->handle('job', where => { run_uuid => $run_uuid })->all;
is(scalar(@jobs), 2, "one job per file");

my $try = $con->handle('try')->insert({ try_uuid => gen_uuid(), job_uuid => $jobs[0]->field('job_uuid'), ord => 1 });
my $tmp = "$dir/events.jsonl.zst";
open my $efh, '>', $tmp or die $!; print $efh "x"; close $efh;
$con->handle('artifact')->insert({
    artifact_uuid => gen_uuid(), run_uuid => $run_uuid, try_uuid => $try->field('try_uuid'),
    name => 'events', type => 'jsonl.zst', local_path => $tmp,
});
$h->finalize_run($run_uuid);
ok(!-e $tmp, "finalize_run deleted the on-disk events file");
my $art = $con->handle('artifact', where => { run_uuid => $run_uuid })->one;
is($art->field('local_path'), undef, "finalize_run nulled local_path");

done_testing;
