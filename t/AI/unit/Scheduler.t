use Test2::V0;
use v5.38;

use Test2::Harness2::Scheduler;

# The scheduler tracks runs and their jobs and decides what to launch next.
# Initial version: one run and one job at a time.

subtest queue_assigns_ords => sub {
    my $s = Test2::Harness2::Scheduler->new;
    my $run = $s->queue_run(files => ['a.t', 'b.t']);

    is($run->{run_ord}, 1, "first run gets run_ord 1");
    ok($run->{run_uuid}, "a run_uuid was assigned");
    is(scalar(@{$run->{jobs}}), 2, "one job per file");
    is($run->{jobs}[0]{job_ord}, 1, "job ords start at 1");
    is($run->{jobs}[1]{job_ord}, 2, "and increment");
    is($run->{jobs}[0]{file}, 'a.t', "carries the file");
    is($run->{jobs}[0]{try}, 1, "first try is 1");

    my $run2 = $s->queue_run(files => ['c.t']);
    is($run2->{run_ord}, 2, "second run gets run_ord 2");
};

subtest one_job_at_a_time => sub {
    my $s = Test2::Harness2::Scheduler->new;
    $s->queue_run(files => ['a.t', 'b.t']);

    my $j1 = $s->next_job;
    ok($j1, "a job is ready to launch");
    is($j1->{file}, 'a.t', "the first pending job");

    $s->mark_running($j1);
    is($s->next_job, undef, "no second job while one is running (max 1)");

    $s->mark_done($j1);
    my $j2 = $s->next_job;
    is($j2->{file}, 'b.t', "next job available after the first finishes");
    $s->mark_running($j2);
    $s->mark_done($j2);

    is($s->next_job, undef, "nothing left to launch");
};

subtest done_detection => sub {
    my $s = Test2::Harness2::Scheduler->new;
    ok(!$s->all_done, "not done before no_more_runs is set");

    $s->no_more_runs;
    ok($s->all_done, "done when told no more runs and none are queued");

    my $s2 = Test2::Harness2::Scheduler->new;
    my $run = $s2->queue_run(files => ['a.t']);
    $s2->no_more_runs;
    ok(!$s2->all_done, "not done while a job is still pending");

    my $j = $s2->next_job;
    $s2->mark_running($j);
    ok(!$s2->all_done, "not done while a job is running");
    $s2->mark_done($j);
    ok($s2->all_done, "done once the last job finishes and no more runs are coming");
};

subtest preassigned_uuids => sub {
    my $s = Test2::Harness2::Scheduler->new;
    my $run = $s->queue_run(run_uuid => 'RUN-X', files => ['a.t'], job_uuids => ['JOB-A']);
    is($run->{run_uuid}, 'RUN-X', "honors a passed run_uuid");
    is($run->{jobs}[0]{job_uuid}, 'JOB-A', "honors a passed job_uuid");
};

done_testing;
