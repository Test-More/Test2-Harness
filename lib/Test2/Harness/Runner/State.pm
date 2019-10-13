package Test2::Harness::Runner::State;
use strict;
use warnings;

our $VERSION = '0.001100';

use Carp qw/croak confess/;
use List::Util qw/first/;

use Test2::Harness::Runner::Constants;

use Test2::Harness::Util::HashBase(
    # These are construction arguments
    qw{
        <staged
        <eager_stages
        <job_count
    },

    qw{
        <ready_stage_lookup
    },

    # These represent the current running state, that is tasks that are
    # currently running. These are used to make sure we do not exceed the job
    # count, and so that we schedule things to avoid conflicts (immiscible,
    # isolation, etc).
    qw{
        <running
        <running_categories
        <running_durations
        <running_conflicts
        <running_tasks
    },

    # These represent the tasks that still need to be run.
    qw{
        +pending_tasks
        +todo
    },
);

sub init {
    my $self = shift;

    croak "You must specify a 'job_count' (1 or greater)"
        unless $self->{+JOB_COUNT};

    croak "You must define a value for the 'staged' attribute"
        unless defined $self->{+STAGED};

    # Eager Stages is a hashref where keys are stages that will run tasks for
    # later stages if they get bored. The value is an arrayref of stages from
    # which they can take tasks.
    $self->{+EAGER_STAGES} //= {};

    $self->{+READY_STAGE_LOOKUP} //= {};

    $self->{+TODO}          = {smoke => 0, main => 0, total => 0, stages => {}};
    $self->{+PENDING_TASKS} = {};

    $self->{+RUNNING} = 0;

    $self->{+RUNNING_CATEGORIES} = {};
    $self->{+RUNNING_DURATIONS}  = {};
    $self->{+RUNNING_CONFLICTS}  = {};
    $self->{+RUNNING_TASKS}      = {};
}

sub todo {
    my $self = shift;
    my ($stage) = @_;

    return $self->{+TODO}->{total} //= 0 unless $stage;

    my $smoke = $self->{+TODO}->{stages}->{smoke}->{$stage} //= 0;
    my $main  = $self->{+TODO}->{stages}->{main}->{$stage} //= 0;

    return $smoke + $main;
}

sub mark_stage_ready {
    my $self = shift;
    my ($stage) = @_;

    $self->{+READY_STAGE_LOOKUP}->{$stage} = 1;
}

sub mark_stage_down {
    my $self = shift;
    my ($stage) = @_;

    delete $self->{+READY_STAGE_LOOKUP}->{$stage};
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;
    return 'default' unless $self->{+STAGED};
    return $task->{stage} || confess "'stage' is missing from the task";
}

sub add_pending_task {
    my $self = shift;
    my ($task) = @_;

    my $cat = $task->{category};
    my $dur = $task->{duration};

    croak "Invalid category: $cat" unless CATEGORIES->{$cat};
    croak "Invalid duration: $dur" unless DURATIONS->{$dur};

    my $stage = $self->task_stage($task);
    my $smoke = $task->{smoke} ? 'smoke' : 'main';

    my $pending = $self->{+PENDING_TASKS} //= {};

    # Walk the tree...
    $pending = $pending->{$smoke} //= {};
    $pending = $pending->{$stage} //= {};
    $pending = $pending->{$cat} //= {};
    $pending = $pending->{$dur} //= [];

    push @$pending => $task;

    $self->_update_todo($task, 1);

    return $task;
}

sub start_task {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id};
    croak "Already running task '$job_id'" if $self->{+RUNNING_TASKS}->{$job_id};
    $self->{+RUNNING_TASKS}->{$job_id} = $task;
    $self->{+RUNNING}++;

    my $cat = $task->{category};
    $self->{+RUNNING_CATEGORIES}->{$cat}++;

    my $dur = $task->{duration};
    $self->{+RUNNING_DURATIONS}->{$dur}++;

    my $cfls = $task->{conflicts} //= [];
    for my $cfl (@$cfls) {
        die "Unexpected parallel conflict '$cfl' ($self->{+RUNNING_CONFLICTS}->{$cfl}) running at this time!"
            if $self->{+RUNNING_CONFLICTS}->{$cfl}++;
    }

    $self->{counter}++;

    return $task;
}

sub stop_task {
    my $self = shift;
    my ($it) = @_;
    my $job_id = ref($it) ? $it->{job_id} : $it;

    my $task = delete $self->{+RUNNING_TASKS}->{$job_id} or croak "Not running task '$job_id'";

    $self->{+RUNNING}--;

    my $cat = $task->{category};
    $self->{+RUNNING_CATEGORIES}->{$cat}--;

    my $dur = $task->{duration};
    $self->{+RUNNING_DURATIONS}->{$dur}--;

    my $cfls = $task->{conflicts} //= [];
    $self->{+RUNNING_CONFLICTS}->{$_}-- for @$cfls;

    return $it;
}

sub pick_and_start {
    my $self = shift;
    my $task = $self->pick_task(@_) or return;
    $self->start_task($task);
    return $task;
}

sub pick_task {
    my $self = shift;

    # Only 1 isolation job can be running and 1 is so let's
    # wait for that one to go away
    return undef if $self->{+RUNNING_CATEGORIES}->{isolation};
    return undef if $self->{+RUNNING} >= $self->{+JOB_COUNT};
    return undef unless $self->{+TODO}->{total};

    my ($run_stage, $task) = $self->_next();

    return undef unless $task;

    $self->_update_todo($task, -1);

    # Returnt he task, but override stage with the designated one, which may be
    # different if we have any eager stages.
    return {%$task, stage => $run_stage};
}

sub _update_todo {
    my $self = shift;
    my ($task, $delta) = @_;

    my $todo = $self->{+TODO} //= {};
    $todo->{total} += $delta;

    my $smoke = $task->{smoke} ? 'smoke' : 'main';
    $todo->{$smoke} += $delta;

    my $stage = $self->task_stage($task);

    $todo->{stages}->{$smoke}->{$stage} += $delta;
}

sub _cat_order {
    my $self = shift;

    my @cat_order = ('general');

    # Only search immiscible if we have no immiscible running
    # put them first if no others are running so we can churn through them
    # early instead of waiting for them to run 1 at a time at the end.
    unshift @cat_order => 'immiscible' unless $self->{+RUNNING_CATEGORIES}->{immiscible};

    # Only search isolation if nothing is running.
    push @cat_order => 'isolation' unless $self->{+RUNNING};

    return \@cat_order;
}

sub _dur_order {
    my $self = shift;

    my $max = $self->{+JOB_COUNT};
    my $maxm1 = $max - 1;

    my $durs = $self->{+RUNNING_DURATIONS};

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

# This returns a list of [STAGE => RUN_STAGE] pairs. 'STAGE' is the stage in
# which we search for tasks, 'RUN_STAGE' is the stage that actually does the
# work. This is what allows us to find tasks for 'eager' stages that are bored.
sub _stage_order {
    my $self = shift;

    my @stage_list = sort keys %{$self->{+READY_STAGE_LOOKUP}};

    # Populate list with all ready stages
    my %seen;
    my @stages = map {[$_ => $_]} grep { !$seen{$_}++ } @stage_list;

    return \@stages unless $self->{+STAGED};

    # Add in any eager stages, but make sure they are last.
    for my $rstage (@stage_list) {
        next unless exists $self->{+EAGER_STAGES}->{$rstage};
        push @stages => map {[$_ => $rstage]} grep { !$seen{$_}++ } @{$self->{+EAGER_STAGES}->{$rstage}};
    }

    return \@stages;
}

sub _next {
    my $self = shift;

    my $pending   = $self->{+PENDING_TASKS};
    my $conflicts = $self->{+RUNNING_CONFLICTS};
    my $cat_order = $self->_cat_order;
    my $dur_order = $self->_dur_order;
    my $stages    = $self->_stage_order();

    # Ugly....
    my $search = $pending;
    for my $smoke (qw/smoke main/) {
        my $search = $search->{$smoke} or next;

        for my $stage_set (@$stages) {
            my ($lstage, $run_by_stage) = @$stage_set;
            my $search = $search->{$lstage} or next;

            for my $lcat (@$cat_order) {
                my $search = $search->{$lcat} or next;

                for my $ldur (@$dur_order) {
                    my $search = $search->{$ldur} or next;

                    for (my $i = 0; $i < @$search; $i++) {
                        # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                        next if first { $conflicts->{$_} } @{$search->[$i]->{conflicts}};

                        return ($run_by_stage => scalar splice(@$search, $i, 1));
                    }
                }
            }
        }
    }

    return;
}

1;
