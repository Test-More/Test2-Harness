package Test2::Harness::Runner::State;
use strict;
use warnings;

our $VERSION = '1.000038';

use Carp qw/croak/;

use File::Spec;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Test2::Harness::Runner::Constants;

use Test2::Harness::Runner::Run;
use Test2::Harness::Util::Queue;

use Test2::Harness::Util::HashBase(
    # These are construction arguments
    qw{
        <eager_stages
        <job_count
        <workdir
        <preloader
        <no_poll
        <resources
    },

    qw{
        <dispatch_file
        <queue_ended

        <pending_tasks <task_lookup
        <pending_runs  +run <stopped_runs
        <pending_spawns

        <running
        <running_categories
        <running_durations
        <running_conflicts
        <running_tasks

        <stage_readiness

        <task_list

        <halted_runs
    },
);

sub init {
    my $self = shift;

    croak "You must specify a 'job_count' (1 or greater)"
        unless $self->{+JOB_COUNT};

    croak "You must specify a workdir"
        unless defined $self->{+WORKDIR};

    $self->{+DISPATCH_FILE} = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($self->{+WORKDIR}, 'dispatch.jsonl'));

    $self->poll;
}

sub run {
    my $self = shift;
    return $self->{+RUN} if $self->{+RUN};
    $self->poll();
    return $self->{+RUN};
}

sub done {
    my $self = shift;

    $self->poll();

    return 0 if $self->{+RUNNING};
    return 0 if keys %{$self->{+PENDING_TASKS} //= {}};

    return 0 if $self->{+RUN};
    return 0 if @{$self->{+PENDING_RUNS} //= []};

    return 0 unless $self->{+QUEUE_ENDED};

    return 1;
}

sub next_task {
    my $self = shift;
    $self->poll();

    while(1) {
        return shift @{$self->{+PENDING_SPAWNS}} if @{$self->{+PENDING_SPAWNS} //= []};
        my $task = shift @{$self->{+TASK_LIST}} or return undef;

        # If we are replaying a state then the task may have already completed,
        # so skip it if it is not in the running lookup.
        next unless $self->{+RUNNING_TASKS}->{$task->{job_id}};

        return $task;
    }
}

sub advance {
    my $self = shift;
    $self->poll();

    $self->advance_run();
    return 0 unless $self->{+RUN};
    return 1 if $self->advance_tasks();
    return $self->clear_finished_run();
}

my %ACTIONS = (
    queue_run   => '_queue_run',
    queue_task  => '_queue_task',
    queue_spawn => '_queue_spawn',
    start_run   => '_start_run',
    start_task  => '_start_task',
    stop_run    => '_stop_run',
    stop_task   => '_stop_task',
    retry_task  => '_retry_task',
    stage_ready => '_stage_ready',
    stage_down  => '_stage_down',
    end_queue   => '_end_queue',
    halt_run    => '_halt_run',
);

sub poll {
    my $self = shift;

    return if $self->{+NO_POLL};

    my $queue = $self->{+DISPATCH_FILE};

    for my $item ($queue->poll) {
        my $data   = $item->[-1];
        my $item   = $data->{item};
        my $action = $data->{action};

        my $sub = $ACTIONS{$action} or die "Invalid action '$action'";

        $self->$sub($item);
    }
}

sub _enqueue {
    my $self = shift;
    my ($action, $item) = @_;
    $self->{+DISPATCH_FILE}->enqueue({action => $action, item => $item, stamp => time, pid => $$});
    $self->poll;
}

sub end_queue  { $_[0]->_enqueue('end_queue' => 1) }
sub _end_queue { $_[0]->{+QUEUE_ENDED} = 1 }

sub halt_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_enqueue(halt_run => $run_id);
}

sub _halt_run {
    my $self = shift;
    my ($run_id) = @_;

    delete $self->{+PENDING_TASKS}->{$run_id};

    $self->{+HALTED_RUNS}->{$run_id}++;
}

sub queue_run {
    my $self = shift;
    my ($run) = @_;
    $self->_enqueue(queue_run => $run);
}

sub _queue_run {
    my $self = shift;
    my ($run) = @_;

    push @{$self->{+PENDING_RUNS}} => Test2::Harness::Runner::Run->new(
        %$run,
        workdir => $self->{+WORKDIR},
    );

    return;
}

sub start_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_enqueue(start_run => $run_id);
}

sub _start_run {
    my $self = shift;
    my ($run_id) = @_;

    my $run = shift @{$self->{+PENDING_RUNS}};
    die "Run stack mismatch, run start requested, but no pending runs to start" unless $run;
    die "Run stack mismatch, run-id does not match next pending run" unless $run->run_id eq $run_id;

    $self->{+RUN} = $run;

    return;
}

sub stop_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_enqueue(stop_run => $run_id);
}

sub _stop_run {
    my $self = shift;
    my ($run_id) = @_;

    $self->{+STOPPED_RUNS}->{$run_id} = 1;

    return;
}

sub queue_spawn {
    my $self = shift;
    my ($spawn) = @_;
    $spawn->{spawn} //= 1;
    $self->_enqueue(queue_spawn => $spawn);
}

sub _queue_spawn {
    my $self = shift;
    my ($spawn) = @_;

    $spawn->{spawn} //= 1;
    $spawn->{use_preload} //= 1;

    $spawn->{stage} //= 'default';
    $spawn->{stage} = $self->task_stage($spawn);

    push @{$self->{+PENDING_SPAWNS}} => $spawn;

    return;
}

sub queue_task {
    my $self = shift;
    my ($task) = @_;
    $self->_enqueue(queue_task => $task);
}

sub _queue_task {
    my $self = shift;
    my ($task) = @_;

    my $job_id = $task->{job_id} or die "Task missing job_id";
    my $run_id = $task->{run_id} or die "Task missing run_id";

    die "Task already in queue" if $self->{+TASK_LOOKUP}->{$job_id};

    return if $self->{+HALTED_RUNS}->{$run_id};

    $self->{+TASK_LOOKUP}->{$job_id} = $task;

    my $pending = $self->task_pending_lookup($task);
    push @{$pending} => $task;

    return;
}

sub start_task {
    my $self = shift;
    my ($spec) = @_;
    my $job_id = $spec->{job_id};
    my $task = $self->{+TASK_LOOKUP}->{$job_id};
    $self->_enqueue(start_task => $spec);
}

sub _start_task {
    my $self = shift;
    my ($spec) = @_;

    my $job_id    = $spec->{job_id} or die "No job_id provided";
    my $run_stage = $spec->{stage}  or die "No stage provided";
    my $res       = $spec->{res}    or die "No res provided";

    my $task = $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to start";

    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);

    my $set = $self->{+PENDING_TASKS}->{$run_id}->{$smoke}->{$stage}->{$cat}->{$dur};
    my $count = @$set;
    @$set = grep { $_->{job_id} ne $job_id } @$set;
    die "Task $job_id was not pending ($count -> " . scalar(@$set) . ")" unless $count > @$set;

    $self->prune_hash($self->{+PENDING_TASKS}, $run_id, $smoke, $stage, $cat, $dur);

    # Set the stage, new task hashref
    $task = {%$task, stage => $run_stage} unless $task->{stage} && $task->{stage} eq $run_stage;

    $task->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
    push @{$task->{test_args}} => @{$res->{args}};

    for my $resource (@{$self->{+RESOURCES}}) {
        my $class = ref($resource);
        my $val = $res->{record}->{$class} // next;
        $resource->record($task->{job_id}, $val);
    }

    die "Already running task $job_id" if $self->{+RUNNING_TASKS}->{$job_id};
    $self->{+RUNNING_TASKS}->{$job_id} = $task;

    push @{$self->{+TASK_LIST}} => $task;

    $self->{+RUNNING}++;
    $self->{+RUNNING_CATEGORIES}->{$cat}++;
    $self->{+RUNNING_DURATIONS}->{$dur}++;

    my $cfls = $task->{conflicts} //= [];
    for my $cfl (@$cfls) {
        die "Unexpected parallel conflict '$cfl' ($self->{+RUNNING_CONFLICTS}->{$cfl}) running at this time!"
            if $self->{+RUNNING_CONFLICTS}->{$cfl}++;
    }

    return;
}

sub stop_task {
    my $self = shift;
    my ($job_id) = @_;
    $self->_enqueue(stop_task => $job_id);
}

sub _stop_task {
    my $self = shift;
    my ($job_id) = @_;

    my $task = delete $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to stop ($job_id)";

    delete $self->{+RUNNING_TASKS}->{$job_id} or die "Task is not running, cannot stop it ($job_id)";

    $_->release($job_id) for @{$self->{+RESOURCES}};

    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);
    $self->{+RUNNING}--;
    $self->{+RUNNING_CATEGORIES}->{$cat}--;
    $self->{+RUNNING_DURATIONS}->{$dur}--;

    my $cfls = $task->{conflicts} //= [];
    $self->{+RUNNING_CONFLICTS}->{$_}-- for @$cfls;

    return;
}

sub retry_task {
    my $self = shift;
    my ($job_id) = @_;

    $self->_enqueue(retry_task => $job_id);
}

sub _retry_task {
    my $self = shift;
    my ($job_id) = @_;

    my $task = $self->{+TASK_LOOKUP}->{$job_id} or die "Could not find task to retry";

    $self->_stop_task($job_id);

    return if $self->{+HALTED_RUNS}->{$task->{run_id}};

    $task = {is_try => 0, %$task};
    $task->{is_try}++;
    $task->{category} = 'isolation' if $self->{+RUN}->retry_isolated;

    $self->_queue_task($task);

    return;
}

sub stage_ready {
    my $self = shift;
    my ($stage) = @_;
    $self->_enqueue(stage_ready => $stage);
}

sub _stage_ready {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE_READINESS}->{$stage} = 1;

    return;
}

sub stage_down {
    my $self = shift;
    my ($stage) = @_;
    $self->_enqueue(stage_down => $stage);
}

sub _stage_down {
    my $self = shift;
    my ($stage) = @_;

    $self->{+STAGE_READINESS}->{$stage} = 0;

    return;
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;

    my $wants = $task->{stage};
    $wants //= 'NOPRELOAD' unless $task->{use_preload};

    return $wants if $self->{+NO_POLL};

    return $self->preloader->task_stage($task->{file}, $wants);
}

sub task_pending_lookup {
    my $self = shift;
    my ($task) = @_;

    my ($run_id, $smoke, $stage, $cat, $dur) = $self->task_fields($task);

    return $self->{+PENDING_TASKS}->{$run_id}->{$smoke}->{$stage}->{$cat}->{$dur} //= [];
}

sub task_fields {
    my $self = shift;
    my ($task) = @_;

    my $run_id = $task->{run_id} or die "No run id provided by task";
    my $smoke  = $task->{smoke} ? 'smoke' : 'main';
    my $stage = $self->task_stage($task);

    my $cat = $task->{category};
    my $dur = $task->{duration};

    die "Invalid category: $cat" unless CATEGORIES->{$cat};
    die "Invalid duration: $dur" unless DURATIONS->{$dur};

    return ($run_id, $smoke, $stage, $cat, $dur);
}

sub prune_hash {
    my $self = shift;
    my ($hash, @path) = @_;

    die "No path!" unless @path;

    my $key = shift @path;

    if (@path) {
        my $empty = $self->prune_hash($hash->{$key}, @path);
        return 0 unless $empty;
    }

    return 1 unless exists $hash->{$key};

    my $ref = ref($hash->{$key});
    if ($ref eq 'HASH') {
        return 0 if keys %{$hash->{$key}};
    }
    elsif ($ref eq 'ARRAY') {
        return 0 if @{$hash->{$key}};
    }

    delete $hash->{$key};
    return 1;
}

sub advance_run {
    my $self = shift;

    return 0 if $self->{+RUN};

    return 0 unless @{$self->{+PENDING_RUNS} //= []};
    $self->start_run($self->{+PENDING_RUNS}->[0]->run_id);

    return 1;
}

sub clear_finished_run {
    my $self = shift;

    my $run = $self->{+RUN} or return 0;

    return 0 unless $self->{+STOPPED_RUNS}->{$run->run_id};
    return 0 if $self->{+PENDING_TASKS}->{$run->run_id};
    return 0 if $self->{+RUNNING};

    delete $self->{+RUN};

    return 1;
}

sub advance_tasks {
    my $self = shift;

    my $max = $self->{+JOB_COUNT} // 0;
    my $cur = $self->{+RUNNING}   // 0;

    return 0 if $cur >= $max;

    my ($run_stage, $task, $res) = $self->_next();

    return 0 unless $task;

    $self->start_task({job_id => $task->{job_id}, stage => $run_stage, res => $res});

    return 1;
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

    my $stage_check = $self->{+STAGE_READINESS} //= {};

    my @stage_list = sort grep { $stage_check->{$_} } keys %$stage_check;

    # Populate list with all ready stages
    my %seen;
    my @stages = map {[$_ => $_]} grep { !$seen{$_}++ } @stage_list;

    # Add in any eager stages, but make sure they are last.
    for my $rstage (@stage_list) {
        next unless exists $self->{+EAGER_STAGES}->{$rstage};
        push @stages => map {[$_ => $rstage]} grep { !$seen{$_}++ } @{$self->{+EAGER_STAGES}->{$rstage}};
    }

    return \@stages;
}

sub _next {
    my $self = shift;

    my $run    = $self->{+RUN} or return;
    my $run_id = $run->run_id;

    my $pending = $self->{+PENDING_TASKS}->{$run_id} or return;

    my $conflicts = $self->{+RUNNING_CONFLICTS};
    my $cat_order = $self->_cat_order;
    my $dur_order = $self->_dur_order;
    my $stages    = $self->_stage_order();
    my $resources = $self->{+RESOURCES};

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

                    for my $task (@$search) {
                        # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                        next if first { $conflicts->{$_} } @{$task->{conflicts}};

                        my $ok = 1;
                        for my $resource (@$resources) {
                            $ok &&= $resource->available($task);
                            last unless $ok;
                        }

                        # Some resource is not available
                        next unless $ok;

                        my $outres = {args => [], env_vars => {}, record => {}};
                        for my $resource (@$resources) {
                            my $res = {args => [], env_vars => {}};
                            $resource->assign($task, $res);
                            push @{$outres->{args}} => @{$res->{args}};
                            $outres->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
                            $outres->{record}->{ref($resource)} = $res->{record};
                        }

                        return ($run_by_stage => $task, $outres);
                    }
                }
            }
        }
    }

    return;
}

1;

__END__


=pod

=encoding UTF-8

=head1 NAME

Test2::Harness::Runner::State - State tracking for the runner.

=head1 DESCRIPTION

This module tracks the state for all running tests. This entire module is
considered an "Implementation Detail". Please do not rely on it always staying
the same, or even existing in the future. Do not use this directly.

=head1 SOURCE

The source code repository for Test2-Harness can be found at
F<http://github.com/Test-More/Test2-Harness/>.

=head1 MAINTAINERS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 AUTHORS

=over 4

=item Chad Granum E<lt>exodist@cpan.orgE<gt>

=back

=head1 COPYRIGHT

Copyright 2020 Chad Granum E<lt>exodist7@gmail.comE<gt>.

This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

See F<http://dev.perl.org/licenses/>

=cut
