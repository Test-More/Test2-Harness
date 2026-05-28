use v5.38;
use Test2::V0;
use File::Temp qw/tempdir/;
use Cwd qw/abs_path/;
use Time::HiRes qw/sleep/;
use Test2::Harness2;

my $root = abs_path('.');
my $pass = "$root/t/AI/scripts/pass.tx";

my $dir = tempdir(CLEANUP => 1);
my $h = Test2::Harness2->new(db_path => "$dir/h.sqlite");
$h->initialize;
my $con = $h->connection;

my $service = $h->start_runner(workdir => "$dir/work");
ok($service && $service->field('service_uuid'), "start_runner returned a service row");
my $runner_uuid = $service->field('runner_uuid');

my $project    = $con->handle('project')->insert({name => 'smoke'});
my $project_id = $project->field('project_id');

my $run = $h->queue_run(
    runner_uuid => $runner_uuid,
    project_id  => $project_id,
    files       => [$pass],
);
$service->update({mode => 'stop'});

# Wait for the run to stop (bounded so a hang fails instead of blocking forever).
my $deadline = time + 30;
while (time < $deadline) {
    $run->refresh;
    last if defined $run->field('stopped');
    sleep 0.1;
}
ok(defined $run->field('stopped'), "run reached stopped state") or diag("run never stopped");
is($run->field('passed'), 1, "passing test -> run passed=1");

my @jobs = $con->handle('job', where => { run_uuid => $run->field('run_uuid') })->all;
is(scalar(@jobs), 1, "one job");
is($jobs[0]->field('passed'), 1, "the job passed");

use File::Spec ();
my $leaked = File::Spec->catfile(File::Spec->tmpdir, "yath-runner-$runner_uuid.jsonl.zst");
ok(!-e $leaked, "no runner events file leaked in tmpdir for this run");

done_testing;
