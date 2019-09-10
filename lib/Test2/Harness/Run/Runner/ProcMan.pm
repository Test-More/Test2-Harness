package Test2::Harness::Run::Runner::ProcMan;
use strict;
use warnings;

use Carp qw/croak/;
use POSIX ":sys_wait_h";
use List::Util qw/first/;
use Time::HiRes qw/sleep time/;
use Fcntl qw/LOCK_EX LOCK_UN LOCK_NB/;

use File::Spec();

use Test2::Harness::Util qw/write_file_atomic/;

use Test2::Harness::Util::File::JSONL();
use Test2::Harness::Run::Queue();

our $VERSION = '0.001100';

use Test2::Harness::Util::HashBase qw{
    -pid
    -queue  -queue_ended
    -jobs   -jobs_file
    -stages

    -_lock -lock_file
    -pending -grouped -todo
    -_pids
    -end_loop_cb

    -_state_cache

    -dir
    -run
    -wait_time
};

my %CATEGORIES = (
    general    => 1,
    isolation  => 1,
    immiscible => 1,
);

my %DURATIONS = (
    long   => 1,
    medium => 1,
    short  => 1,
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

        my $dur = $task->{duration};
        $dur = 'medium' unless $dur && $DURATIONS{$dur};
        $task->{duration} = $dur;

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

    delete $self->{+_STATE_CACHE};

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
        kill("-$sig", $pid) or kill($sig, $pid) or warn "Could not kill pid";
    }

    return;
}

# This process is going to exit, do any final waiting
sub finish {
    my $self = shift;

    while (keys %{$self->{+_PIDS}}) {
        $self->wait_on_jobs;
    }

    return;
}

sub wait_on_jobs {
    my $self = shift;
    my %args = @_;

    my $cleared_one;
    for my $pid (keys %{$self->{+_PIDS}}) {
        my $check = waitpid($pid, WNOHANG);
        my $exit  = $?;

        next unless $check || $args{force_exit};

        $cleared_one = 1;
        my $params = delete $self->{+_PIDS}->{$pid};

        unless ($check == $pid) {
            $exit = -1;
            warn "Waitpid returned $check for pid $pid" if $check;
        }

        $self->write_exit(%$params, exit => $exit, stamp => time);
    }

    $self->unlock unless keys %{$self->{+_PIDS}};

    if ($cleared_one) {
        delete $self->{+_STATE_CACHE};
    }
    else {
        my $wait_time = $self->{+WAIT_TIME};
        sleep($wait_time) if $wait_time;
    }

    return $cleared_one;
}

sub write_remaining_exits {
    my $self = shift;
    $self->wait_on_jobs(force_exit => 1);
}

sub write_exit {
    my $self   = shift;
    my %params = @_;

    my $file = File::Spec->catfile($params{dir}, 'exit');

    write_file_atomic($file, "$params{exit} $params{stamp}");
}

sub next {
    my $self = shift;
    my ($stage) = @_;

    # Get a new task to run.
    my $task = $self->_next($stage);

    # If there are no more tasks then wait on the remaining jobs to complete.
    unless ($task) {
        $self->wait_on_jobs() while keys %{$self->{+_PIDS}};
    }

    # Return task or undef if we're done.
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

sub _running_state {
    my $self = shift;

    return $self->{+_STATE_CACHE} if $self->{+_STATE_CACHE};

    my $running = 0;
    my %cats;
    my %durs;
    my %active_conflicts;

    for my $job (values %{$self->{+_PIDS}}) {
        $running++;
        $cats{$job->{task}->{category}}++;
        $durs{$job->{task}->{duration}}++;

        # Mark all the conflicts which the actively jobs have asserted.
        foreach my $conflict (@{$job->{task}->{conflicts}}) {
            $active_conflicts{$conflict}++;

            # This should never happen.
            $active_conflicts{$conflict} < 2 or die("Unexpected parallel conflict '$conflict' ($active_conflicts{$conflict}) running at this time!");
        }
    }

    return $self->{+_STATE_CACHE} = {
        running    => $running,
        categories => \%cats,
        durations  => \%durs,
        conflicts  => \%active_conflicts,
    };
}

sub _next_simple {
    my $self = shift;
    my ($stage) = @_;

    # If we're only allowing 1 job at a time, then just give the
    # next one on the list, unless 1 is running
    return shift @{$self->{+PENDING}->{$stage} ||= []};
}

sub _next_concurrent {
    my $self = shift;
    my ($stage) = @_;

    my $todo = $self->{+TODO}->{$stage} ||= do { my $todo = 0; \$todo };

    my $state = $self->_running_state();
    my ($running, $cats, $durs, $active_conflicts) = @{$state}{qw/running categories durations conflicts/};

    # Only 1 isolation job can be running and 1 is so let's
    # wait for that pid to die.
    return if $cats->{isolation};

    my $cat_order = $self->_cat_order($state);
    my $dur_order = $self->_dur_order($state);
    my $grouped   = $self->_group_items($stage);

    for my $lcat (@$cat_order) {
        for my $ldur (@$dur_order) {
            my $search = $grouped->{$lcat}->{$ldur} or next;

            for (my $i = 0; $i < @$search; $i++) {
                # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                my $job_conflicts = $search->[$i]->{conflicts};
                next if first { $active_conflicts->{$_} } @$job_conflicts;

                $$todo--;
                return scalar splice(@$search, $i, 1);
            }
        }
    }

    return;
}

sub _group_items {
    my $self = shift;
    my ($stage) = @_;

    my $grouped = $self->{+GROUPED}->{$stage} ||= {};
    my $list    = $self->{+PENDING}->{$stage} ||= [];
    my $todo    = $self->{+TODO}->{$stage}    ||= do { my $todo = 0; \$todo };

    while (my $item = shift @$list) {
        my $cat = $item->{category};
        my $dur = $item->{duration};

        die "Invalid category: $cat" unless $CATEGORIES{$cat};
        die "Invalid duration: $dur" unless $DURATIONS{$dur};

        $$todo++;
        push @{$grouped->{$cat}->{$dur}} => $item;
    }

    return $grouped;
}

sub _cat_order {
    my $self = shift;
    my ($state) = @_;

    $state ||= $self->_running_state();

    my @cat_order = ('general');

    # Only search immiscible if we have no immsicible running
    unshift @cat_order => 'immiscible' unless $state->{categories}->{immiscible};

    # Only search isolation if nothing it running.
    push @cat_order => 'isolation' unless $state->{running};

    return \@cat_order;
}

sub _dur_order {
    my $self = shift;
    my ($state) = @_;

    my $max = $self->{+RUN}->job_count;
    my $maxm1 = $max - 1;

    $state ||= $self->_running_state();
    my $durs = $state->{durations};

    # 'short' is always ok.
    my @dur_order = ('short');

    # long and medium should be on the front of the search unless we are
    # already running (max - 1) tests of the duration We want long first if
    # we are not saturation on them, followed by medium, whcih is why they
    # are listed in this order.
    for my $c (qw/medium long/) {
        if ($durs->{$c} && $durs->{$c} >= $maxm1) {
            push @dur_order => $c;    # Back of the list
        }
        else {
            unshift @dur_order => $c;    # Front of the list
        }
    }

    return \@dur_order;
}

sub _next {
    my $self = shift;
    my ($stage) = @_;

    my $todo = $self->{+TODO}->{$stage}    ||= do { my $todo = 0; \$todo };
    my $list = $self->{+PENDING}->{$stage} ||= [];

    my $end_cb = $self->{+END_LOOP_CB};

    my $max = $self->{+RUN}->job_count || 1;

    my $next_meth = $max <= 1 ? '_next_simple' : '_next_concurrent';

    my $iter = 0;
    while (@$list || $$todo || !$self->{+QUEUE_ENDED}) {
        return if $end_cb && $end_cb->(); # End loop callback.

        my $task = $self->_next_iter($stage, $iter++, $max, $next_meth);

        return $task if $task;
    }

    return;
}

sub _next_iter {
    my $self = shift;
    my ($stage, $iter, $max, $next_meth) = @_;

    sleep($self->{+WAIT_TIME}) if $iter && $self->{+WAIT_TIME};

    # Check the job files for active and newly kicked off tasks.
    # Updates $list which we use to decide if we need to keep looping.
    $self->poll_tasks;

    # Reap any completed PIDs
    $self->wait_on_jobs;

    if ($self->{+LOCK_FILE}) {
        my $todo = ${$self->{+TODO}->{$stage}} || @{$self->{+PENDING}->{$stage}};

        unless ($todo) {
            $self->unlock;
            return;
        }

        # Make sure we have the lock
        return unless $self->lock;
    }

    # No new jobs yet to kick off yet because too many are running.
    return if keys(%{$self->{+_PIDS}}) >= $max;

    my $task = $self->$next_meth($stage) or return;
    return $task;
}

1;
