use v5.38;
use Test2::V0;
use File::Temp qw/tempdir/;
use Test2::Util::UUID qw/gen_uuid/;
use Test2::Harness2;
use Test2::Harness2::Scheduler;

my $dir = tempdir(CLEANUP => 1);
my $h   = Test2::Harness2->new(db_path => "$dir/h.sqlite");
$h->initialize;
my $con = $h->connection;

my $runner_uuid = gen_uuid();
$con->handle('runner')->insert({runner_uuid => $runner_uuid});
my $project = $con->handle('project')->insert({name => 'sched-test'});
my $project_id = $project->field('project_id');
my $run_uuid = $h->queue_run(
    runner_uuid => $runner_uuid,
    project_id  => $project_id,
    files       => ['t/AI/scripts/pass.tx'],
)->field('run_uuid');

my $sched = Test2::Harness2::Scheduler->new(con => $con, runner_uuid => $runner_uuid);

my $job = $sched->next_job;
ok($job, "scheduler handed back a pending job");

my $try = $sched->start_try($job);
is($try->field('ord'), 1, "first try ord is 1");
ok($try->field('try_uuid'), "try has a uuid");

$try->update({passed => 1});
$sched->finish_try($job, $try);
is($con->handle('job')->by_id($job->field('job_uuid'))->field('passed'), 1, "job passed set true");

ok(!$sched->next_job,               "no more pending jobs once resolved");
ok($sched->run_complete($run_uuid), "run reports complete when all jobs resolved");

# --- default (retry_limit 0): a failing try that asks to retry still resolves ---
my $run2 = $h->queue_run(runner_uuid => $runner_uuid, project_id => $project_id, files => ['t/AI/scripts/retry.tx'])->field('run_uuid');
my $job2 = $sched->next_job;
ok($job2, "got the second run's job");
my $t2 = $sched->start_try($job2);
$t2->update({passed => 0, should_retry => 1});
$sched->finish_try($job2, $t2);
is(
    $con->handle('job')->by_id($job2->field('job_uuid'))->field('passed'), 0,
    "default retry_limit 0: should_retry is ignored, job resolves as failed"
);

# --- retry_limit 1: should_retry triggers a second try, then resolves ---
my $run3    = $h->queue_run(runner_uuid => $runner_uuid, project_id => $project_id, files => ['t/AI/scripts/retry2.tx'])->field('run_uuid');
my $sched_r = Test2::Harness2::Scheduler->new(con => $con, runner_uuid => $runner_uuid, retry_limit => 1);
# run1 + run2 jobs are already resolved, so run3's job is the only pending one.
my $job3 = $sched_r->next_job;
ok($job3, "got the third run's job");
is(lc($job3->field('run_uuid')), lc($run3), "it is run3's job");
my $t3a = $sched_r->start_try($job3);
is($t3a->field('ord'), 1, "first try ord 1");
$t3a->update({passed => 0, should_retry => 1});
$sched_r->finish_try($job3, $t3a);
is(
    $con->handle('job')->by_id($job3->field('job_uuid'))->field('passed'), undef,
    "retry_limit 1: job left unresolved after first failing try wanting retry"
);
my $t3b = $sched_r->start_try($job3);
is($t3b->field('ord'), 2, "second try ord 2");
$t3b->update({passed => 1});
$sched_r->finish_try($job3, $t3b);
is(
    $con->handle('job')->by_id($job3->field('job_uuid'))->field('passed'), 1,
    "retry_limit 1: job passes once a retry passes"
);

done_testing;
