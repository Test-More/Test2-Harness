package Test2::Harness::Run::Runner::ProcMan;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use List::Util qw/first/;
use Time::HiRes qw/sleep/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;

use File::Spec();

use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Util::File::JSONL();
use Test2::Harness::Run::Queue();

our $VERSION = '0.001061';

use Test2::Harness::Util::HashBase qw{
    -pid
    -queue  -queue_ended
    -jobs   -jobs_file -jobs_seen
    -stages

    -slots

    -_lock -lock_file
    -pending
    -_pids
    -end_loop_cb

    -dir
    -run
    -wait_time
};

my %CATEGORIES = (
    long       => 1,
    medium     => 1,
    general    => 1,
    isolation  => 1,
    immiscible => 1,
);

sub init {
    my $self = shift;

    croak "'run' is a required attribute"
        unless $self->{+RUN};

    croak "'dir' is a required attribute"
        unless $self->{+DIR};

    croak "'queue' is a required attribute"
        unless $self->{+QUEUE};

    croak "'jobs_file' is a required attribute"
        unless $self->{+JOBS_FILE};

    croak "'stages' is a required attribute"
        unless $self->{+STAGES};

    $self->{+PID} = $$;

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+JOBS} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE}, use_write_lock => 1);
    $self->{+JOBS_SEEN} = {};

    $self->read_jobs();
}

sub read_jobs {
    my $self = shift;

    my $jobs = $self->{+JOBS};
    return unless $jobs->exists;

    my $jobs_seen = $self->{+JOBS_SEEN};
    for my $job ($jobs->poll) {
        $jobs_seen->{$job->{job_id}}++;
    }
}

sub preload_queue {
    my $self = shift;

    my $run = $self->{+RUN};

    return unless $run->finite;

    my $wait_time = $self->{+WAIT_TIME};
    until ($self->{+QUEUE_ENDED}) {
        $self->poll_tasks() and next;
        sleep($wait_time) if $wait_time;
    }

    return 1;
}

sub poll_tasks {
    my $self = shift;

    return if $self->{+QUEUE_ENDED};

    my $queue = $self->{+QUEUE};
    if ($self->{+PID} != $$) {
        $queue->reset;
        $self->{+PID} = $$;
    }

    my $added = 0;
    for my $item ($queue->poll) {
        my ($spos, $epos, $task) = @$item;

        $added++;

        if (!$task) {
            $self->{+QUEUE_ENDED} = 1;
            last;
        }

        my $cat = $task->{category};
        $cat = 'general' unless $cat && $CATEGORIES{$cat};
        $task->{category} = $cat;

        my $stage = $task->{stage};
        $stage = 'default' unless $stage && $self->{+STAGES}->{$stage};
        $task->{stage} = $stage;

        push @{$self->{+PENDING}->{$stage}} => $task;
    }

    return $added;
}

sub job_started {
    my $self   = shift;
    my %params = @_;

    my $pid = $params{pid};
    my $job = $params{job};

    $self->{+_PIDS}->{$pid} = \%params;

    $self->{+JOBS}->write({%{$job->TO_JSON}, pid => $pid});
}

# Children of this process should be killed
sub kill {
    my $self = shift;
    my ($sig) = @_;
    $sig = 'TERM' unless defined $sig;

    for my $pid (keys %{$self->{+_PIDS}}) {
        kill($sig, $pid) or warn "Could not kill pid";
    }

    return;
}

# This process is going to exit, do any final waiting
sub finish {
    my $self = shift;

    my $wait_time = $self->{+WAIT_TIME};
    while (keys %{$self->{+_PIDS}}) {
        $self->wait_on_jobs and next;
        sleep($wait_time) if $wait_time;
    }

    return;
}

sub wait_on_jobs {
    my $self = shift;
    my %params = @_;

    for my $pid (keys %{$self->{+_PIDS}}) {
        my $check = waitpid($pid, WNOHANG);
        my $exit = $?;

        next unless $check || $params{force_exit};

        my $params = delete $self->{+_PIDS}->{$pid};
        my $cat = $params->{task}->{category};
        $cat = 'long' if $cat eq 'medium';
        $self->{+SLOTS}->{$cat}++;

        unless ($check == $pid) {
            $exit = -1;
            warn "Waitpid returned $check for pid $pid" if $check;
        }

        $self->write_exit(%$params, exit => $exit);
    }

    $self->unlock unless keys %{$self->{+_PIDS}};
}

sub write_remaining_exits {
    my $self = shift;
    $self->wait_on_jobs(force_exit => 1);
}

sub write_exit {
    my $self = shift;
    my %params = @_;
    my $file = File::Spec->catfile($params{dir}, 'exit');
    write_file_atomic($file, $params{exit});
}

sub next {
    my $self = shift;
    my ($stage) = @_;

    my $task = $self->_next($stage);

    unless ($task) {
        $self->wait_on_jobs() while keys %{$self->{+_PIDS}};
    }

    return $task;
}

sub lock {
    my $self = shift;
    return 1 if $self->{+_LOCK};
    return 1 unless $self->{+LOCK_FILE};

    open(my $lock, '>>', $self->{+LOCK_FILE}) or die "Could not open lock file: $!";
    flock($lock, LOCK_EX | LOCK_NB) or return 0;
    $self->{+_LOCK} = $lock;

    return 1;
}

sub unlock {
    my $self = shift;

    my $lock = delete $self->{+_LOCK} or return 1;
    flock($lock, LOCK_UN);
    close($lock);
    return 1;
}

sub _next {
    my $self = shift;
    my ($stage) = @_;

    my $end_cb    = $self->{+END_LOOP_CB};
    my $list      = $self->{+PENDING}->{$stage} ||= [];
    my $wait_time = $self->{+WAIT_TIME};
    my $jobs_seen = $self->{+JOBS_SEEN};

    my $max = $self->{+RUN}->job_count || 1;
    my $slow = $max - 1;

    my $slots = $self->{+SLOTS} ||= {
        immiscible => 1,
        isolation  => 1,
        long       => $max - 1,
        general    => $max,
    };

    my $first = 1;
    while (@$list || !$self->{+QUEUE_ENDED}) {
        return if $end_cb && $end_cb->();
        sleep $wait_time unless $first;
        $first = 0;

        $self->poll_tasks;
        $self->wait_on_jobs;

        next unless $self->lock;

        $self->read_jobs;
        @$list = grep { !$jobs_seen->{$_->{job_id}} } @$list;
        unless (@$list) {
            $self->unlock;
            next;
        }

        my $running = 0;
        my %cats;
        for my $job (values %{$self->{+_PIDS}}) {
            $running++;
            $cats{$job->{task}->{category}}++;
        }

        # At max jobs already
        next if $running >= $max;

        # None if isolation is running
        next if $cats{isolation};

        return shift @$list if $max == 1;

        my $fallback;
        for(my $i = 0; $i < @$list; $i++) {
            my $cat = $list->[$i]->{category};
            $cat = 'long' if $cat eq 'medium';

            die "Unknown category: $cat" unless defined $slots->{$cat};

            $fallback = $i if $cat eq 'long';

            next unless $slots->{$cat};
            $self->{+SLOTS}->{$cat}--;
            return scalar splice(@$list, $i, 1);
        }

        # If we have a long one, but no generals, we can go ahead and run the long one
        return scalar splice(@$list, $fallback, 1)
            if $fallback;
    }
}

1;
