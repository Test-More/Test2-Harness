package Test2::Harness::Collector;
use strict;
use warnings;

our $VERSION = '0.001100';

use Test2::Harness::Collector::JobDir;

use Test2::Harness::Util::Queue;
use Time::HiRes qw/sleep/;

use Test2::Harness::Util::HashBase qw{
    <workdir
    <run_id
    <show_runner_output
    <settings
    <run_dir
    <runner_pid

    +task_file +task_queue +tasks_done
    +jobs_file +jobs_queue +jobs_done  +jobs

    <action
};

sub init {
    my $self = shift;

    my $run_dir = File::Spec->catdir($self->{+WORKDIR}, $self->{+RUN_ID});
    die "Could not find run dir" unless -d $run_dir;
    $self->{+RUN_DIR} = $run_dir;
}

sub process {
    my $self = shift;

    while (1) {
        my $count = 0;
        $count += $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};
        $count += $self->process_tasks();

        my $jobs = $self->jobs;

        unless (keys %$jobs) {
            last if $self->{+JOBS_DONE};
            last if $self->runner_done;
        }

        while(my ($job_id, $job) = each %$jobs) {
            my $e_count = 0;
            for my $event ($job->poll(1000)) {
                $self->{+ACTION}->($event);
                $count++;
            }

            delete $jobs->{$job_id} if $job->done && !$e_count;
            $count += $e_count;
        }

        sleep 0.02 unless $count;
    }

    # One last slurp
    $self->process_tasks();
    $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};

    $self->{+ACTION}->(undef) if $self->{+JOBS_DONE} && $self->{+TASKS_DONE};

    return;
}

sub process_runner_output {
    return 0;
}

sub process_tasks {
    my $self = shift;

    return 0 if $self->{+TASKS_DONE};

    my $queue = $self->tasks_queue or return 0;

    my $count = 0;
    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        unless ($task) {
            $self->{+TASKS_DONE} = 1;
            last;
        }

    }

    return $count
}

sub jobs {
    my $self = shift;

    my $jobs = $self->{+JOBS} //= {};

    return $jobs if $self->{+JOBS_DONE};

    my $queue = $self->jobs_queue or return $jobs;

    for my $item ($queue->poll) {
        my ($spos, $epos, $job) = @$item;

        unless ($job) {
            $self->{+JOBS_DONE} = 1;
            last;
        }

        my $job_id = $job->{job_id} or die "No job id!";

        $jobs->{$job_id} = Test2::Harness::Collector::JobDir->new(
            job_id     => $job_id,
            run_id     => $self->{+RUN_ID},
            runner_pid => $self->{+RUNNER_PID},
            job_root   => File::Spec->catdir($self->{+RUN_DIR}, $job_id),
        );
    }

    return $jobs;
}

sub _harness_event {
    my $self = shift;
    my ($job_id) = shift;

    my $run = $self->run;

    return Test2::Harness::Event->new(
        job_id     => $job_id,
        event_id   => gen_uuid(),
        run_id     => $run->run_id,
        facet_data => {@_},
    );
}


sub jobs_queue {
    my $self = shift;

    return $self->{+JOBS_QUEUE} if $self->{+JOBS_QUEUE};

    my $jobs_file = $self->{+JOBS_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'jobs.jsonl');

    return unless -f $jobs_file;

    return $self->{+JOBS_QUEUE} = Test2::Harness::Util::Queue->new(file => $jobs_file);
}

sub tasks_queue {
    my $self = shift;

    return $self->{+TASK_QUEUE} if $self->{+TASK_QUEUE};

    my $tasks_file = $self->{+TASK_FILE} //= File::Spec->catfile($self->{+RUN_DIR}, 'queue.jsonl');

    return unless -f $tasks_file;

    return $self->{+TASK_QUEUE} = Test2::Harness::Util::Queue->new(file => $tasks_file);
}


1;

__END__

$self->_harness_event(0, harness_run => $self->{+RUN}, about => {no_display => 1});
$self->_harness_event(0, info => [{tag => 'INTERNAL', debug => 0, details => $_}])
$self->_harness_event(0, info => [{tag => 'INTERNAL', debug => 1, details => $_}])

$self->_harness_event(
    $job_id,
    harness_job_launch => {retry => $self->{+IS_RETRY}},
    harness_job        => $job,
);

$self->_harness_event(
    $jfeed->job_id,
    harness_job_end => {},
);

harness_job
harness_job_end
harness_job_exit
harness_job_launch
harness_job_start
