package Test2::Harness::Run::Runner::ProcMan;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use List::Util qw/first/;
use Time::HiRes qw/sleep/;

use File::Spec();

use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Util::File::JSONL();
use Test2::Harness::Run::Queue();

our $VERSION = '0.001016';

use Test2::Harness::Util::HashBase qw{
    -queue  -queue_ended
    -jobs   -jobs_file
    -stages

    -_pending
    -_running
    -_pids

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

    croak "'queue' is a required attribute"
        unless $self->{+QUEUE};

    croak "'jobs_file' is a required attribute"
        unless $self->{+JOBS_FILE};

    croak "'stages' is a required attribute"
        unless $self->{+STAGES};

    $self->{+WAIT_TIME} = 0.02 unless defined $self->{+WAIT_TIME};

    $self->{+JOBS} ||= Test2::Harness::Util::File::JSONL->new(name => $self->{+JOBS_FILE});

    $self->{+_PENDING} = {};
    $self->{+_RUNNING} = {
        __ALL__ => 0,
        map { $_ => 0 } keys %CATEGORIES,
    };

    $self->preload_queue();
}

sub preload_queue {
    my $self = shift;

    my $run = $self->{+RUN};

    return $self->poll_tasks unless $run->finite;

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

        push @{$self->{+_PENDING}->{$stage} ||= []} => $task;
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

sub bump {
    my $self = shift;
    my ($cat) = @_;

    $self->{+_RUNNING}->{$cat}++;
    $self->{+_RUNNING}->{__ALL__}++;
}

sub unbump {
    my $self = shift;
    my ($cat) = @_;

    $self->{+_RUNNING}->{$cat}--;
    $self->{+_RUNNING}->{__ALL__}--;
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
        $self->unbump($cat);

        unless ($check == $pid) {
            $exit = -1;
            warn "Waitpid returned $check for pid $pid" if $check;
        }

        $self->write_exit(%$params, exit => $exit);
    }
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

    my $pending = $self->{+_PENDING}->{$stage} ||= [];

    return undef unless @$pending;

    my $wait_time = $self->{+WAIT_TIME};

    my $task;
    while(@$pending) {
        $self->wait_on_jobs;
        $self->poll_tasks;

        $task = $self->fetch_task($pending);
        last if $task;

        sleep($wait_time) if $wait_time;
    }

    return undef unless $task;

    my $cat = $task->{category};
    $self->bump($cat);

    return $task;
}

sub fetch_task {
    my $self = shift;
    my ($pending) = @_;

    my $running = $self->{+_RUNNING};

    my $run = $self->{+RUN};
    my $job_count = $run->job_count;

    # Cannot run anything now
    return undef if $running->{__ALL__} >= $job_count;

    return shift @$pending if $job_count < 2;

    # Cannot run anything else if an isolation task is running
    return undef if $running->{isolation};

    return $self->fetch_finite($pending) if $run->finite;
    return $self->fetch_fair($pending);
}

sub fetch_finite {
    my $self = shift;
    my ($pending) = @_;

    my $running = $self->{+_RUNNING};

    my $run = $self->{+RUN};
    my $job_count = $run->job_count;
    my $lng_count = $job_count - 1;

    my $imm_running = $running->{immiscible};
    my $lng_running = $running->{long};
    my $med_running = $running->{medium};
    my $not_short = $lng_running + $med_running;

    my ($backup, $found);
    for (my $i = 0; $i < @$pending; $i++) {
        my $task = $pending->[$i];
        my $cat = $task->{category};

        next if $cat eq 'isolation' && $running->{__ALL__};
        next if $cat eq 'immiscible' && $imm_running;

        $backup = $i unless defined $task;
        if ($not_short >= $lng_count) {
            next if $cat eq 'long';
            next if $cat eq 'medium';
        }

        $found = $i;
        last;
    }

    if (!defined($found)) {
        return undef unless defined($backup);
        $found = $backup;
    }

    return splice(@$pending, $found, 1);
}

sub fetch_fair {
    my $self = shift;
    my ($pending) = @_;

    my $next_is_iso = @$pending && $pending->[0]->{category} eq 'isolation';

    # This is the same as finite, except when the next up is isolation, we
    # cannot save those forever
    return $self->fetch_finite($pending) unless $next_is_iso;

    my $running = $self->{+_RUNNING};

    # If nothing else is running we can run the isolation
    return shift @$pending unless $running->{__ALL__};

    # If there is a long job we can run some short ones
    return unless $running->{long};

    my $found;
    for (my $i = 0; $i < @$pending; $i++) {
        my $task = $pending->[$i];
        my $cat = $task->{category};
        next unless $cat eq 'general';

        $found = $i;
        last;
    }

    return undef unless defined $found;
    return splice(@$pending, $found, 1);
}

1;
