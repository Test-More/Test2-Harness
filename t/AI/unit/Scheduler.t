use Test2::V0;
use v5.38;

use Test2::Harness2::Scheduler;

# The scheduler tracks runs and their jobs and decides what to launch next.
# Initial version: one run and one job at a time.

subtest queue_assigns_ords => sub {
    my $s = Test2::Harness2::Scheduler->new;
    my $run = $s->queue_run(files => ['a.t', 'b.t']);

    is($run->run_ord, 1, "first run gets run_ord 1");
    ok($run->run_uuid, "a run_uuid was assigned");
    is(scalar(@{$run->jobs}), 2, "one job per file");
    is($run->jobs->[0]->job_ord, 1, "job ords start at 1");
    is($run->jobs->[1]->job_ord, 2, "and increment");
    is($run->jobs->[0]->relative, 'a.t', "carries the file");
    is($run->jobs->[0]->run_uuid, $run->run_uuid, "job carries its run_uuid");
    is($run->jobs->[0]->run_ord, $run->run_ord, "job carries its run_ord");
    is($run->jobs->[0]->try, 1, "first try is 1");
    is($run->jobs->[0]->state, 'pending', "first state is pending");

    my $run2 = $s->queue_run(files => ['c.t']);
    is($run2->run_ord, 2, "second run gets run_ord 2");
};

subtest one_job_at_a_time => sub {
    my $s = Test2::Harness2::Scheduler->new;
    $s->queue_run(files => ['a.t', 'b.t']);

    my $j1 = $s->next_job;
    ok($j1, "a job is ready to launch");
    is($j1->relative, 'a.t', "the first pending job");

    $s->mark_running($j1);
    is($j1->state, 'running', "mark_running set the state");
    is($s->next_job, undef, "no second job while one is running (max 1)");

    $s->mark_done($j1);
    is($j1->state, 'done', "mark_done set the state");
    my $j2 = $s->next_job;
    is($j2->relative, 'b.t', "next job available after the first finishes");
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

subtest queue_from_specs => sub {
    my $s = Test2::Harness2::Scheduler->new;

    # Specs as a producer would serialize them (provisional ids the harness
    # must override, plus scan-derived state it must preserve).
    my $specs = [
        {
            run_uuid => 'CLIENT-RUN', run_ord => 1,
            job_uuid => 'JOB-A', job_ord => 1,
            absolute => '/abs/a.t', relative => 'a.t',
            category => 'isolation', duration => 'short',
            conflicts => ['db'], switches => ['-w'],
        },
        {
            run_uuid => 'CLIENT-RUN', run_ord => 1,
            job_uuid => 'JOB-B', job_ord => 2,
            absolute => '/abs/b.t', relative => 'b.t',
        },
    ];

    my $run = $s->queue_run(run_uuid => 'CLIENT-RUN', jobs => $specs);

    is($run->run_uuid, 'CLIENT-RUN', "honored the client run_uuid");
    is($run->run_ord, 1, "assigned an authoritative run_ord");
    is(scalar(@{$run->jobs}), 2, "one job per spec");

    my $j = $run->jobs->[0];
    is($j->job_uuid, 'JOB-A', "honored the spec job_uuid");
    is($j->job_ord, 1, "honored the spec job_ord");
    is($j->run_ord, $run->run_ord, "job run_ord matches the assigned run_ord");
    is($j->relative, 'a.t', "preserved scan-derived relative");
    is($j->category, 'isolation', "preserved scan-derived category");
    is([$j->conflicts_list], ['db'], "preserved scan-derived conflicts");
    is($j->state, 'pending', "queued fresh as pending");
    is($j->try, 1, "queued at try 1");

    # run_ord increments for the next run even when fed specs.
    my $run2 = $s->queue_run(jobs => [{absolute => '/abs/c.t', relative => 'c.t'}]);
    is($run2->run_ord, 2, "second run_ord increments");
    ok($run2->jobs->[0]->job_uuid, "vivified a job_uuid when the spec omitted one");
    is($run2->jobs->[0]->job_ord, 1, "vivified job_ord from position");
};

subtest preassigned_uuids => sub {
    my $s = Test2::Harness2::Scheduler->new;
    my $run = $s->queue_run(run_uuid => 'RUN-X', files => ['a.t'], job_uuids => ['JOB-A']);
    is($run->run_uuid, 'RUN-X', "honors a passed run_uuid");
    is($run->jobs->[0]->job_uuid, 'JOB-A', "honors a passed job_uuid");
};

subtest new_started_runs => sub {
    my $s = Test2::Harness2::Scheduler->new;
    is([$s->new_started_runs], [], "nothing started before any run is queued");

    my $run = $s->queue_run(files => ['a.t', 'b.t']);
    is([$s->new_started_runs], [$run->run_uuid], "the queued run is considered/started");
    is([$s->new_started_runs], [], "started is drain-once");

    # Drain it fully; the next run becomes the considered one.
    my $j1 = $s->next_job; $s->mark_running($j1); $s->mark_done($j1);
    my $j2 = $s->next_job; $s->mark_running($j2); $s->mark_done($j2);

    my $run2 = $s->queue_run(files => ['c.t']);
    is([$s->new_started_runs], [$run2->run_uuid], "second run started once first is done");
};

subtest new_completed_runs => sub {
    my $s   = Test2::Harness2::Scheduler->new;
    my $run = $s->queue_run(files => ['a.t', 'b.t']);
    is([$s->new_completed_runs], [], "run not complete while jobs pending");

    my $j1 = $s->next_job; $s->mark_running($j1); $s->mark_done($j1);
    is([$s->new_completed_runs], [], "run not complete with one job left");

    my $j2 = $s->next_job; $s->mark_running($j2); $s->mark_done($j2);
    is([$s->new_completed_runs], [$run->run_uuid], "run complete when all jobs done");
    is([$s->new_completed_runs], [], "completed is drain-once");
};

done_testing;
