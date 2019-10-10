package Test2::Harness::Collector;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak/;

use Test2::Harness::Collector::JobDir;

use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::Queue;
use Time::HiRes qw/sleep/;
use File::Spec;

use Test2::Harness::Util::HashBase qw{
    <run
    <workdir
    <run_id
    <show_runner_output
    <settings
    <run_dir
    <runner_pid +runner_exited

    +runner_stdout +runner_stderr

    +task_file +task_queue +tasks_done +tasks
    +jobs_file +jobs_queue +jobs_done  +jobs
    +pending

    <wait_time
    <action
};

sub init {
    my $self = shift;

    croak "'run' is required"
        unless $self->{+RUN};

    my $run_dir = File::Spec->catdir($self->{+WORKDIR}, $self->{+RUN_ID});
    die "Could not find run dir" unless -d $run_dir;
    $self->{+RUN_DIR} = $run_dir;

    $self->{+WAIT_TIME} //= 0.02;

    $self->{+ACTION}->($self->_harness_event(0, harness_run => $self->{+RUN}, about => {no_display => 1}));
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

        while(my ($job_try, $jdir) = each %$jobs) {
            my $e_count = 0;
            for my $event ($jdir->poll(1000)) {
                $self->{+ACTION}->($event);
                $count++;
            }

            $count += $e_count;
            next if $e_count;
            my $done = $jdir->done or next;

            delete $jobs->{$job_try};

            delete $self->{+PENDING}->{$jdir->job_id} unless $done->{retry};
        }

        last if !$count && $self->runner_exited;
        sleep $self->{+WAIT_TIME} unless $count;
    }

    # One last slurp
    $self->process_runner_output if $self->{+SHOW_RUNNER_OUTPUT};

    $self->{+ACTION}->(undef) if $self->{+JOBS_DONE} && $self->{+TASKS_DONE};

    return;
}

sub runner_done {
    my $self = shift;

    return 0 if keys %{$self->{+PENDING}};
    return 1;
}

sub runner_exited {
    my $self = shift;
    my $pid = $self->{+RUNNER_PID} or return undef;

    return $self->{+RUNNER_EXITED} if $self->{+RUNNER_EXITED};

    return 0 if kill(0, $pid);

    return $self->{+RUNNER_EXITED} = 1;
}

sub process_runner_output {
    my $self = shift;

    return unless $self->{show_runner_output};

    my $stdout = $self->{+RUNNER_STDOUT} //= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'output.log'),
    );

    for my $line ($stdout->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, info => [{details => $line, tag => 'INTERNAL'}]);
        $self->{+ACTION}->($e);
    }

    my $stderr = $self->{+RUNNER_STDERR} //= Test2::Harness::Util::File::Stream->new(
        name => File::Spec->catfile($self->{+WORKDIR}, 'error.log'),
    );

    for my $line ($stderr->poll()) {
        chomp($line);
        my $e = $self->_harness_event(0, info => [{details => $line, tag => 'INTERNAL', debug => 1}]);
        $self->{+ACTION}->($e);
    }
}

sub process_tasks {
    my $self = shift;

    return 0 if $self->{+TASKS_DONE};

    my $queue = $self->tasks_queue or return 0;

    my $count = 0;
    for my $item ($queue->poll) {
        $count++;
        my ($spos, $epos, $task) = @$item;

        unless ($task) {
            $self->{+TASKS_DONE} = 1;
            last;
        }

        my $job_id = $task->{job_id} or die "No job id!";
        $self->{+TASKS}->{$job_id} = $task;
        $self->{+PENDING}->{$job_id} = 1 + ($task->{retry} || $self->run->retry || 0);

        my $e = $self->_harness_event($job_id, 'harness_job_queued' => $task);
        $self->{+ACTION}->($e);
    }

    return $count;
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

        die "Found job without a task!" unless $self->{+TASKS}->{$job_id};

        $self->{+PENDING}->{$job_id}--;
        delete $self->{+PENDING}->{$job_id} if $self->{+PENDING}->{$job_id} < 1;

        my $file = $job->{file};
        my $e = $self->_harness_event(
            $job_id,
            harness_job        => $job,
            harness_job_start  => {
                details => "Job $job_id started at $job->{stamp}",
                job_id  => $job_id,
                stamp   => $job->{stamp},
                file    => $file,
                rel_file => File::Spec->abs2rel($file),
                abs_file => File::Spec->rel2abs($file),
            },
            harness_job_launch => {
                stamp => $job->{stamp},
                retry => $job->{is_try},
            },
        );

        $self->{+ACTION}->($e);

        my $job_try = $job_id . '+' . $job->{is_try};

        $jobs->{$job_try} = Test2::Harness::Collector::JobDir->new(
            job_id     => $job_id,
            run_id     => $self->{+RUN_ID},
            runner_pid => $self->{+RUNNER_PID},
            job_root   => File::Spec->catdir($self->{+RUN_DIR}, $job_try),
        );
    }

    return $jobs;
}

sub _harness_event {
    my $self = shift;
    my ($job_id) = shift;

    return Test2::Harness::Event->new(
        job_id     => $job_id,
        event_id   => gen_uuid(),
        run_id     => $self->{+RUN_ID},
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
