use Test2::V0 -target => 'Test2::Harness::Runner::State';
# HARNESS-DURATION-SHORT

use ok $CLASS;

use File::Temp qw/tempdir/;

use Test2::Harness::Settings;

my $RUN_ID = 'test-run';

# Drive the scheduler by hand and check which tasks it is willing to run
# together.
#
# 'tasks' is an ordered list of NAME => TASK_SPEC pairs; the spec carries only
# what the case is about (usually 'conflicts' and/or 'shares'), everything else
# gets a default.
#
# 'steps' is an ordered list of pairs describing what should happen:
#
#   running => \@names   Let the scheduler start everything it can, then check
#                        that exactly these tasks are running.
#   stop    => \@names   Pretend these tasks finished. Nothing forks here, so
#                        this is the only way a task ever completes.
#   queue   => \@tasks   Queue more NAME => TASK_SPEC pairs mid-run.
sub schedule_ok {
    my ($name, %params) = @_;

    my @tasks     = @{$params{tasks}};
    my @steps     = @{$params{steps}};
    my $job_count = $params{job_count} // 10;

    my $ctx = context();

    my $settings = Test2::Harness::Settings->new(
        runner => {
            job_count     => $job_count,
            slots_per_job => $job_count,
            resources     => [],
        },
    );

    my $state = $CLASS->new(
        workdir      => tempdir(CLEANUP => 1),
        settings     => $settings,
        eager_stages => {},
    );

    $state->queue_run({run_id => $RUN_ID});
    $state->stage_ready('DEFAULT');

    my %name_for;
    my $queue = sub {
        my (@tasks) = @_;

        while (@tasks) {
            my ($task_name, $spec) = splice(@tasks, 0, 2);

            my $job_id = "job-$task_name";
            $name_for{$job_id} = $task_name;

            $state->queue_task({
                run_id      => $RUN_ID,
                job_id      => $job_id,
                category    => 'general',
                duration    => 'short',
                use_preload => 1,
                %$spec,
            });
        }
    };

    $queue->(@tasks);

    my $out = subtest $name => sub {
        while (@steps) {
            my ($action, $args) = splice(@steps, 0, 2);

            if ($action eq 'running') {
                1 while $state->advance;

                my @running = map { $name_for{$_} } keys %{$state->running_tasks // {}};
                is([sort @running], [sort @$args], "Running: " . join(', ' => sort @$args));
            }
            elsif ($action eq 'stop') {
                $state->stop_task("job-$_") for @$args;
            }
            elsif ($action eq 'queue') {
                $queue->(@$args);
            }
            else {
                die "Unknown step '$action'";
            }
        }
    };

    $ctx->release;

    return $out;
}

schedule_ok(
    "Two exclusive claims on one name cannot run together",
    tasks => [
        a => {conflicts => ['db']},
        b => {conflicts => ['db']},
    ],
    steps => [
        running => [qw/a/],
        stop    => [qw/a/],
        running => [qw/b/],
    ],
);

schedule_ok(
    "Any number of shared claims on one name run together",
    tasks => [
        a => {shares => ['db']},
        b => {shares => ['db']},
        c => {shares => ['db']},
    ],
    steps => [running => [qw/a b c/]],
);

schedule_ok(
    "Running shared claims keep an exclusive claim waiting, then release it",
    tasks => [
        a => {shares => ['db']},
        b => {shares => ['db']},
    ],
    steps => [
        running => [qw/a b/],
        queue   => [c => {conflicts => ['db']}],
        running => [qw/a b/],
        stop    => [qw/a/],
        running => [qw/b/],
        stop    => [qw/b/],
        running => [qw/c/],
    ],
);

schedule_ok(
    "An exclusive claim is picked ahead of shared claims on the same name",
    tasks => [
        a => {shares    => ['db']},
        b => {shares    => ['db']},
        c => {conflicts => ['db']},
    ],
    steps => [
        running => [qw/c/],
        stop    => [qw/c/],
        running => [qw/a b/],
    ],
);

schedule_ok(
    "An exclusive claim keeps shared claims waiting",
    tasks => [
        a => {conflicts => ['db']},
        b => {shares    => ['db']},
        c => {shares    => ['db']},
    ],
    steps => [
        running => [qw/a/],
        stop    => [qw/a/],
        running => [qw/b c/],
    ],
);

schedule_ok(
    "Claims on unrelated names do not interact",
    tasks => [
        a => {shares    => ['db']},
        b => {conflicts => ['mysql']},
        c => {shares    => ['mysql']},
        d => {conflicts => ['db']},
    ],
    steps => [
        running => [qw/b d/],
        stop    => [qw/b d/],
        running => [qw/a c/],
    ],
);

schedule_ok(
    "One task can hold an exclusive claim and a shared claim at once",
    tasks => [
        a => {conflicts => ['db'], shares => ['mysql']},
        b => {shares    => ['mysql']},
        c => {shares    => ['db']},
        d => {conflicts => ['mysql']},
    ],
    steps => [
        running => [qw/a b/],
        stop    => [qw/a b/],
        running => [qw/c d/],
    ],
);

schedule_ok(
    "A task with no 'shares' key at all still dispatches",
    tasks => [
        a => {},
        b => {conflicts => ['db']},
    ],
    steps => [running => [qw/a b/]],
);

schedule_ok(
    "A name claimed both ways by one task does not block that task",
    tasks => [
        a => {conflicts => ['db'], shares => ['db']},
        b => {shares    => ['db']},
    ],
    steps => [
        running => [qw/a/],
        stop    => [qw/a/],
        running => [qw/b/],
    ],
);

schedule_ok(
    "The job limiter still caps how many run at once",
    job_count => 2,
    tasks     => [
        a => {shares => ['db']},
        b => {shares => ['db']},
        c => {shares => ['db']},
    ],
    steps => [
        running => [qw/a b/],
        stop    => [qw/a b/],
        running => [qw/c/],
    ],
);

done_testing;
