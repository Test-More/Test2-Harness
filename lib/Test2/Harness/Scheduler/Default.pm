package Test2::Harness::Scheduler::Default;
use strict;
use warnings;

our $VERSION = '2.000000';

use Carp qw/croak/;
use POSIX qw/:sys_wait_h/;
use List::Util qw/first/;
use Time::HiRes qw/time/;

use Test2::Harness::Scheduler::Default::Run;
use Test2::Harness::IPC::Protocol;
use Test2::Harness::Event;

use Test2::Harness::Util qw/hash_purge/;
use Test2::Harness::IPC::Util qw/ipc_warn/;
use Test2::Harness::Util::UUID qw/gen_uuid/;
use Test2::Harness::Util::JSON qw/encode_pretty_json/;

use parent 'Test2::Harness::Scheduler';
use Test2::Harness::Util::HashBase qw{
    <run_order
    <runs

    <running

    <terminated

    <children
};

sub init {
    my $self = shift;

    croak "'runner' is a required attribute" unless $self->{+RUNNER};

    $self->SUPER::init();

    delete $self->{+TERMINATED};

    $self->{+RUN_ORDER} = [];    # run-id's in order they should be run
    $self->{+RUNS}      = {};    # { run_id => {..., jobs => \@COMPLETE_LIST, jobs_todo => ..., jobs_complete => {}} }
    $self->{+RUNNING}   = {};
    $self->{+CHILDREN}  = {};    # pid => ...?
}

sub terminate {
    my $self = shift;
    my ($reason) = @_;

    $reason ||= 1;

    return $self->{+TERMINATED} ||= $reason;
}

sub start {
    my $self = shift;
    my ($ipc) = @_;
    $self->runner->start($self, $ipc);
}

sub register_child {
    my $self = shift;
    my ($pid, $callback) = @_;
    $self->{+CHILDREN}->{$pid} = $callback;
}

sub queue_run {
    my $self = shift;
    my ($run) = @_;

    my $run_id = $run->run_id;

    croak "run id '$run_id' already in queue" if $self->{+RUNS}->{$run_id};

    push @{$self->{+RUN_ORDER}} => $run_id;
    $run = $self->{+RUNS}->{$run_id} = Test2::Harness::Scheduler::Default::Run->new(%$run);

    my $stamp = time;

    my $con = $run->connect;
    $con->send_message({
        stamp    => time,
        event_id   => gen_uuid,
        run_id     => $run->run_id,
        facet_data => {harness_run => $run->data_no_jobs},
    });

    for my $job (@{$run->jobs}) {
        $con->send_message(Test2::Harness::Event->new(
            event_id => gen_uuid,
            run_id   => $run->run_id,
            job_id   => $job->job_id,
            job_try  => $job->try,
            stamp    => time,

            facet_data => {
                harness_job_queued => {
                    file   => $job->test_file->file,
                    job_id => $job->job_id,
                    stamp  => $stamp,
                }
            },
        ));

        $self->job_container($run->todo, $job, vivify => 1)->{$job->{job_id}} = $job;
    }

    return $run_id;
}

sub job_container {
    my $self = shift;
    croak "Insufficient arguments" unless @_;
    $_[0] //= {};
    my ($cont, $job, %params) = @_;

    for my $step ($self->job_fields($job)) {
        return unless exists($cont->{$step}) || $params{vivify};
        $cont = $cont->{$step} //= {};
    }

    return $cont;
}

sub job_fields {
    my $self = shift;
    my ($job) = @_;

    my $tf = $job->test_file;

    my $smoke = $tf->check_feature('smoke') ? 'smoke' : 'main';

    my $stage = $self->runner->job_stage($job, $tf->check_stage) // 'NONE';

    my $cat = $tf->check_category // 'general';
    my $dur = $tf->check_duration // 'medium';

    my $confl = @{$tf->conflicts_list // []} ? 'conflict' : 'none';

    return ($smoke, $stage, $cat, $dur, $confl);
}

sub wait_on_kids {
    my $self = shift;

    local ($?, $!);

    while (1) {
        my $pid = waitpid(-1, WNOHANG);
        my $exit = $?;

        last if $pid < 1;

        my $cb = delete $self->{+CHILDREN}->{$pid} or die "Reaped untracked process!";
        $cb->(pid => $pid, exit => $exit, scheduler => $self) if $cb && ref($cb) eq 'CODE';
    }
}

sub finalize_completed_runs {
    my $self = shift;

    my @run_order;
    for my $run_id (@{$self->{+RUN_ORDER}}) {
        my $run = $self->{+RUNS}->{$run_id} or next;

        my $todo = $run->todo;
        hash_purge($todo);

        my $keep = 0;
        unless ($run->halt) {
            $keep ||= keys %$todo;
        }

        $keep ||= keys %{$run->running};

        if ($keep) {
            push @run_order => $run_id;
            next;
        }

        $self->finalize_run($run_id);
    }

    @{$self->{+RUN_ORDER}} = @run_order;
}

sub finalize_run {
    my $self = shift;
    my ($run_id) = @_;

    my $run = delete $self->{+RUNS}->{$run_id} or return;

    return if eval {
        $run->connect->send_message({
            run_complete => {
                run_id => $run_id,
                jobs   => {map { ($_->job_id => $_->results) } @{$run->complete}},
            }
        });

        1;
    };

    ipc_warn(error => $@);
}

sub job_update {
    my $self = shift;
    my ($update) = @_;

    my $run_id = $update->{run_id};
    my $job_id = $update->{job_id};

    my $run = $self->{+RUNS}->{$run_id} or die "Invalid run!";
    my $job = $run->job_lookup->{$job_id} or die "Invalid job!";

    if (defined $update->{halt}) {
        $run->set_halt($update->{halt} || 'halted');
    }

    if (my $pid = $update->{pid}) {
        $self->{+RUNNING}->{jobs}->{$job_id}->{pid} = $pid;
    }

    if (my $res = $update->{result}) {
        push @{$job->{results}} => $res;

        warn "FIXME: retry";
        push @{$run->complete} => $job;

        my $info = delete $run->running->{$job->job_id};
        $info->{cleanup}->($self) if $info->{cleanup};
    }
}

sub abort {
    my $self = shift;
    my (@runs) = @_;

    my %runs = map { $_ => $self->{+RUNS}->{$_} } @runs ? @runs : keys %{$self->{+RUNS} // {}};

    for my $run (values %runs) {
        $run->set_halt('aborted');
    }

    for my $job (values %{$self->{+RUNNING}->{jobs} // {}}) {
        next unless $runs{$job->{run}->run_id};
        my $pid = $job->{pid} // next;
        CORE::kill('TERM', $pid);
        $job->{killed} = 1;
    }
}

sub kill {
    my $self = shift;
    $self->abort;
}

sub manage_tests {
    my $self = shift;

    for my $job_id (keys %{$self->{+RUNNING}->{jobs}}) {
        my $job_data = $self->{+RUNNING}->{jobs}->{$job_id};

        # Timeout if it takes too long to start
        if (!$job_data->{pid}) {
            my $delta = time - $job_data;
            my $timeout = $self->runner->test_settings->event_timeout || 30;

            if ($delta > $timeout) {
                warn "Job '$job_id' took too long to start, timing it out: " . encode_pretty_json($job_data->{job});
                my $info = delete $job_data->{run}->running->{$job_id};
                $info->{cleanup}->($self) if $info->{cleanup};
            }
        }

        # Kill pid if run is terminated and it has a pid
        if ($job_data->{run}->halt && !$job_data->{killed}) {
            next unless $job_data->{pid};
            CORE::kill('TERM', $job_data->{pid});
            $job_data->{killed} = 1;
        }
    }
}

sub advance {
    my $self = shift;

    $self->finalize_completed_runs;
    $self->wait_on_kids;
    $self->manage_tests;

    return unless $self->runner->ready;

    my ($run, $job, $stage, $cat, $dur, $confl, $job_set) = $self->next_job() or return;

    my $ok = $self->runner->launch_job($stage, $run, $job);

    # If the job could not be started
    unless ($ok) {
        $job_set->{$job->job_id} = $job;
        return 1;
    }

    my $info = {
        job => $job,
        run => $run,
        pid     => undef,
        start   => time,
        cleanup => sub {
            my $scheduler = shift;

            $scheduler->{+RUNNING}->{categories}->{$cat}--;
            $scheduler->{+RUNNING}->{durations}->{$dur}--;
            $scheduler->{+RUNNING}->{conflicts}->{$_}-- for @{$confl || []};
            $scheduler->{+RUNNING}->{total}--;

            # The next several bits are to avoid memory leaks
            my $info1 = delete $run->running->{$job->job_id};
            my $info2 = delete $self->{+RUNNING}->{jobs}->{$job->job_id};
            for my $info ($info1, $info2) {
                next unless $info;
                delete $info->{cleanup};
                delete $info->{job};
            }
            $job = undef;
            $run = undef;
        },
    };

    $run->running->{$job->job_id} = $info;
    $self->{+RUNNING}->{jobs}->{$job->job_id} = $info;

    $self->{+RUNNING}->{categories}->{$cat}++;
    $self->{+RUNNING}->{durations}->{$dur}++;
    $self->{+RUNNING}->{conflicts}->{$_}++ for @{$confl || []};
    $self->{+RUNNING}->{total}++;

    return 1;
}

sub category_order {
    my $self = shift;

    my @cat_order = ('conflicts', 'general');

    my $running = $self->running;

    # Only search immiscible if we have no immiscible running
    # put them first if no others are running so we can churn through them
    # early instead of waiting for them to run 1 at a time at the end.
    unshift @cat_order => 'immiscible' unless $running->{categories}->{immiscible};

    # Only search isolation if nothing is running.
    unshift @cat_order => 'isolation' unless $running->{total};

    return \@cat_order;
}

sub duration_order { [qw/long medium short/] }

sub next_job {
    my $self = shift;

    my $running = $self->{+RUNNING};

    my $stages = $self->runner->stage_sets;
    my $cat_order = $self->category_order;
    my $dur_order = $self->duration_order;

    for my $run_id (@{$self->{+RUN_ORDER}}) {
        my $run = $self->{+RUNS}->{$run_id};
        next if $run->halt;
        my $search = $run->todo or next;

        for my $smoke (qw/smoke main/) {
            my $search = $search->{$smoke} or next;

            for my $stage_set (@$stages) {
                my ($lstage, $run_by_stage) = @$stage_set;
                my $search = $search->{$lstage} or next;

                for my $cat (@$cat_order) {
                    my $search = $search->{$cat} or next;

                    for my $dur (@$dur_order) {
                        my $search = $search->{$dur} or next;

                        for my $confl (qw/conflict none/) {
                            my $search = $search->{$confl} or next;

                            for my $job_id (keys %$search) {
                                my $job = $search->{$job_id};

                                # Skip if conflicting tests are running
                                my $confl = $job->test_file->conflicts_list;
                                next if first { $running->{conflicts}->{$_} } @$confl;

                                delete $search->{$job_id};
                                return ($run, $job, $run_by_stage, $cat, $dur, $confl, $search);
                            }
                        }
                    }
                }
            }
        }
    }

    return;
}

sub DESTROY {
    my $self = shift;

    $self->terminate('DESTROY');
}

1;


__END__
use Carp qw/croak confess/;
use List::Util qw/first/;
use Scalar::Util qw/blessed/;
use Time::HiRes qw/time/;
use Test2::Harness::Util qw/mod2file/;
use Linux::Inotify2;

use Test2::Harness::Task;

use parent 'Test2::Harness::IPC::Util::TxnState::Shared';
use Test2::Harness::Util::HashBase qw{
    <run_order
    <runs

    <pending
    <running

    <run_pid

    <inotify <watch

    done
};

sub init {
    my $self = shift;

    $self->SUPER::init();

    $self->{+RUNS}      //= {};
    $self->{+PENDING}   //= {};
    $self->{+RUNNING}   //= {};
    $self->{+RUN_ORDER} //= [];
}

sub post_data_hook {
    my $self = shift;

    my $pending = $self->{+PENDING};

    for my $run_id (keys %{$pending // {}}) {
        for my $test (@{$pending->{$run_id} // []}) {
            Test2::Harness::Task->FROM_JSON($test) unless blessed($test);
        }
    }

    return $self;
}

sub queue {
    my $self = shift;
    my ($run_id) = @_;

    $self->transaction(w => sub {
        confess "run '$run_id' has already been queued"
            if $self->{+RUNS}->{$run_id};

        confess "Queue has been terminated"
            if @{$self->{+RUN_ORDER}} && !defined($self->{+RUN_ORDER}->[-1]);

        push @{$self->{+RUN_ORDER} //= []} => $run_id;
        $self->{+RUNS}->{$run_id} = 1;

        my $pending = $self->{+PENDING} //= {};

        for my $task (@{$self->sort_tasks($self->state->shared_all([task => $run_id]))}) {
            if ($task->is_test) {
                push @{$pending->{$run_id}} => $task->state_field;
            }
            else {
                $self->state->shared_get('runner', $task->stage)->queue_job($task->state_field);
            }
        }
    });
}

sub retry {
    my $self = shift;
    my ($task) = @_;

    confess "rerun can only be used for test tasks" unless $task->is_test;

    my $run_id = $task->run_id or die "No run id";
    my $run = $self->runs->{$run_id} or confess "Invalid run_id '$run_id', run not found";

    $task = $task->clone;
    $task->increment_try;

    $task->set_category('isolation') if $run->retry_isolated;

    $self->transaction(w => sub {
        my $pending = $self->{+PENDING} //= {};
        unshift @{$pending->{$run_id}} => $task->state_field;
    });
}

my %CAT_ORDER = (
    isolation  => 1,
    immiscible => 2,
    conflicts  => 3,
    general    => 4,
);

my %DURATION_ORDER = (
    long   => 1,
    medium => 2,
    short  => 3,
);

sub sort_tasks {
    my $self = shift;
    my ($tasks) = @_;

    @$tasks = sort {
        my $out = 0;

        $out ||= $a->is_test <=> $b->is_test;

        # Retries to the front
        $out ||= $b->is_try <=> $a->is_try;

        # Smoke early
        $out ||= $b->smoke <=> $a->smoke;

        # Categegories by order
        $out ||= $CAT_ORDER{$a->category} <=> $CAT_ORDER{$b->category};

        # More Conflicts means run earlier
        $out ||= @{$b->conflicts // []} <=> @{$a->conflicts // []};

        # Duration if possible
        my $ad = $a->duration;
        my $bd = $b->duration;
        if ($ad && $bd) {
            $ad = lc($ad);
            $bd = lc($bd);

            if ($DURATION_ORDER{$ad} && $DURATION_ORDER{$bd}) {
                $out = $DURATION_ORDER{$ad} <=> $DURATION_ORDER{$bd};
            }
            else {
                $out = $ad <=> $bd;
            }
        }

        $out;
    } @$tasks;

    return $tasks;
}

sub terminate_queue {
    my $self = shift;

    $self->transaction(w => sub {
        return if @{$self->{+RUN_ORDER} // []} && !defined($self->{+RUN_ORDER}->[-1]);
        push @{$self->{+RUN_ORDER} //= []} => undef;
    });
}

sub truncate_queue {
    my $self = shift;
    my (%params) = @_;

    $self->transaction(w => sub {
        $self->{+RUN_ORDER} = [];
        $self->{+RUNS} = {};
        $self->{+PENDING} = {};

        if ($params{terminate}) {
            push @{$self->{+RUN_ORDER} //= []} => undef;
            $self->{+DONE} = 1;
        }
    });
}

sub before_write { shift->unwatch }
sub after_write { shift->watch }

sub inotify {
    my $self = shift;
    $self->{+INOTIFY} //= my $inotify = Linux::Inotify2->new or $self->harness->abort("Could not initialize Linux::Inotify2: $!");
    return $self->{+INOTIFY};
}

sub watch {
    my $self = shift;

    return $self->{+WATCH} if $self->{+WATCH};

    print "Adding Watch\n";

    my $inotify = $self->inotify;
    my $harness = $self->state;
    $self->{+WATCH} = $inotify->watch($harness->state_file, IN_MODIFY | IN_ONESHOT, sub { $self->iterate($inotify) }) or $harness->abort("Could not watch state file: $!");
    return $self->{+WATCH};
}

sub unwatch {
    my $self = shift;

    print "Canceling Watch\n";

    my $watch = $self->{+WATCH} or return;
    $watch->cancel;
}

sub run {
    my $self = shift;

    if (my $run_pid = $self->{+RUN_PID}) {
        confess "Only pid '$run_pid' can run the scheduler, this is pid '$$'" unless $$ == $run_pid;
        confess "Scheduler is already running";
    }
    else {
        $self->transaction(w => sub { $self->{+RUN_PID} = $$ });
    }

    print "STATE: " . $self->state->state_file . "\n";

    my $child = 0;
    local $SIG{CHLD} = sub { $child++; }; # Required to break inotify poll

    while(1) {
        print "LOOP!\n";
        $self->iterate();
        last if $self->done;
        $self->inotify->poll;
        last if $self->done;
    }

    $self->transaction(w => sub { delete $self->{+RUN_PID} });

    return 0;
}

sub ready_stages {
    my $self = shift;

    my $harness = $self->state;

    my %ready;

    $self->transaction(r => sub {
        %ready = map { my $n = $_->stage_name; ($n => $n) } grep { $_->ready } @{$harness->shared_all('runners')};
    });

    my $base = $harness->shared_get(runner => 'base');

    my %out;

    # This will iterate all stages and their children. Any ready eager stage
    # found will be set as the value of it's child stages in the %out hash.
    # This will make the deepest ready-eager stage the assigned value for any
    # child stage.
    my %seen;
    my @todo = @{$base->children};
    while (my $s = shift @todo) {
        next if $seen{$s}++;

        my $name = $s->name;
        my $e = $s->eager;

        for my $child (@{$s->children}) {
            push @todo => $child;
            next unless $e && $ready{$name};

            my $cname = $child->name;
            $out{$cname} = $name;
        }
    }

    # Use our eager stages, but override with ready stages where applicable.
    # 'base' is always ready
    return {%out, %ready, base => 'base'};
}

sub iterate {
    my $self = shift;
    print "ITERATE\n";

    my $runner = $self->state->shared_get('runner', 'base');

    if (!$runner->is_running && defined $runner->exit_code) {
        $self->{+DONE} = 1;
        return;
    }

    return if $self->done;

    $self->refresh;
    return if $self->done;

    # If there are no runs to do then we do nothing
    my $run_order = $self->run_order;
    return unless $run_order && @$run_order;

    # Only run is undef, that means we have terminated the queue, and we have
    # completed all runs up until the termination
    if (@$run_order && !defined($run_order->[0])) {
        $self->{+DONE} = 1;
        return;
    }

    return unless $self->pending;
    my $harness  = $self->state;
    my $runs     = $self->runs;
    my @limiters = grep { $_->is_job_limiter || $_->applies_to_all_tests } @{$self->state->shared_all('resources')};

    my $hit_limit = 0;
    my $limited = sub {
        return 1 if $hit_limit;
        $hit_limit = first { !$_->available } @limiters;
    };

    my $stages = $self->ready_stages;

    for my $run_id (@$run_order) {
        last unless $run_id;
        return if $limited->();

        # If any 'isolated' test is running, then we cannot do anything.
        last if $self->{+RUNNING}->{categories}->{isolation};

        my $run = $runs->{$run_id} or confess "No run found for run-id '$run_id'";

        my $isolation = 0;

        $self->transaction(
            w => sub {
                my $pending = $self->pending;
                my $run_pending = $pending->{$run_id} //= [];

                my @keep;
                while (my $task_id = shift @$run_pending) {
                    push @keep => $task_id;
                    my $test = $harness->shared_get(@$task_id);

                    last if $limited->();    # Do not make this one return.

                    $isolation++ if $test->category eq 'isolation';

                    my $spec = $self->can_run($test, $stages) or next;
                    pop @keep;               # We will handle it now

                    if (my $unavailable = $spec->{unavailable}) {
                        use Data::Dumper;
                        print "SKIP: $test->{file} " . Dumper($spec);
                        $runner->skip_test($test, $unavailable);
                    }
                    else {
                        print "RUN: $test->{file}\n";
                        my $stage = $spec->{stage};
                        my $task  = $spec->{task};
                        print $task->{file} . "\n";
                        $self->start_running($task);
                        my $runner = $self->state->shared_get(runner => $stage);
                        $runner->queue_task($task);
                    }
                }

                unshift @$run_pending => @keep;
            }
        );

        return if $limited->();

        # Do not progress to the next run if there are isolation tests that
        # need to execute. We might never finish this run if we do.
        return if $isolation;
    }
}

sub can_run {
    my $self = shift;
    my ($test, $stages) = @_;

    # Do not run if there is a conflict
    my $conflicts = $self->{+RUNNING}->{conflicts};
    return if first { $conflicts->{$_} } @{$test->conflicts};

    # Do not run if isolation is not right
    return if $self->{+RUNNING}->{categories}->{isolation};
    return if $test->category eq 'isolation' && $self->{+RUNNING}->{total};

    # Do not run if no stage can run it
    # We need a list of stages, as well as what stages they can emulate (early-eager)
    my $stage = $stages->{$test->stage} or return;

    # Resource check+assignment
    my @resources = @{$self->state->shared_all('resource')};

    my (@free, @busy, @unavailable);
    for my $res (@resources) {
        next unless $res->is_job_limiter || $res->applies_to_all_tests || $res->applies_to_test($test);
        my $av = $res->available_for_test($test);

        if ($av) {    # Available
            push @free => [$res, $av];
        }
        elsif (!defined($av)) {    # Will never be available
            push @unavailable => $res;
        }
        else {                     # Busy, try again
            push @busy => $res;
        }
    }

    return {unavailable => \@unavailable} if @unavailable;

    return if @busy;

    my $env = {};
    for my $res_set (@free) {
        my ($res, $av) = @$res_set;
        $res->allocate_for_test($test, $av, env => $env);
    }

    my $task = $test->clone;
    $task->set_env_vars({%{$task->env_vars // {}}, %$env});

    return {stage => $stage, task => $task};
}

sub start_running {
    my $self = shift;
    my ($task) = @_;

    $self->transaction(w => sub {
        $self->{+RUNNING}->{by_job_id}->{$task->job_id} = $task;
        $self->{+RUNNING}->{total}++;
        $self->{+RUNNING}->{by_run_id}->{$task->run_id}++;
        $self->{+RUNNING}->{categories}->{$task->category}++;
        $self->{+RUNNING}->{conflicts}->{$_}++ for @{$task->conflicts};
    });
}

sub stop_running {
    my $self = shift;
    my ($task, %params) = @_;

    $self->transaction(w => sub {
        delete $self->{+RUNNING}->{by_job_id}->{$task->job_id};
        $self->{+RUNNING}->{total}--;
        $self->{+RUNNING}->{by_run_id}->{$task->run_id}--;
        $self->{+RUNNING}->{categories}->{$task->category}--;
        $self->{+RUNNING}->{conflicts}->{$_}-- for @{$task->conflicts // []};

        $self->retry($task) if $params{retry};
    });
}

sub category_order {
    my $self = shift;

    my @cat_order = ('conflicts', 'general');

    my $running = $self->running;

    # Only search immiscible if we have no immiscible running
    # put them first if no others are running so we can churn through them
    # early instead of waiting for them to run 1 at a time at the end.
    unshift @cat_order => 'immiscible' unless $running->{categories}->{immiscible};

    # Only search isolation if nothing is running.
    unshift @cat_order => 'isolation' unless $running->{total};

    return \@cat_order;
}

sub TO_JSON {
    my $self = shift;
    my $out = $self->SUPER::TO_JSON();
    delete $out->{+INOTIFY};
    delete $out->{+WATCH};
    return $out;
}

1;

__END__


my %SORTED;
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

                    # Make sure anything with conflicts runs early.
                    unless ($SORTED{$search}++) {
                        @$search = sort { scalar(@{$b->{conflicts}}) <=> scalar(@{$a->{conflicts}}) } @$search;
                    }

                    for my $task (@$search) {
                        # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                        next if first { $conflicts->{$_} } @{$task->{conflicts}};

                        my $ok = 1;
                        my @resource_skip;
                        for my $resource (@$resources) {
                            my $out = $resource->available($task) || 0; # normalize false to 0

                            push @resource_skip => ref($resource) || $resource if $out < 0;

                            $ok &&= $out;

                            # If we have a temporarily unavailable resource we
                            # skip, but if any resource is never avilable
                            # (skip) we want to finish the loop to add them all
                            # for the skip message.
                            last if !$ok && !@resource_skip;
                        }

                        # Some resource is temporarily not available
                        next unless $ok;

                        my $outres = {args => [], env_vars => {}, record => {}};

                        my @out = ($run_by_stage => $task, $outres);

                        my @record = @$resources;

                        if (@resource_skip) {
                            push @out => (resource_skip => \@resource_skip);

                            # Only the job limiter resources need to be recorded.
                            @record = grep { $_->job_limiter } @record;
                        }

                        for my $resource (@record) {
                            my $res = {args => [], env_vars => {}};
                            $resource->assign($task, $res);
                            push @{$outres->{args}} => @{$res->{args}};
                            $outres->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
                            $outres->{record}->{ref($resource)} = $res->{record};
                        }

                        return @out;
                    }
                }
            }
        }
    }

    return;
}

package Test2::Harness::Runner::State;
use strict;
use warnings;

our $VERSION = '1.000152';

use Carp qw/croak/;

use File::Spec;
use Time::HiRes qw/time/;
use List::Util qw/first/;

use Test2::Harness::Util qw/mod2file/;

use Test2::Harness::State;

use Test2::Harness::Settings;
use Test2::Harness::Runner::Constants;

use Test2::Harness::Runner::Run;
use Test2::Harness::Util::Queue;

use Test2::Harness::Util::UUID qw/gen_uuid/;

use Test2::Harness::Util::HashBase(
    # These are construction arguments
    qw{
        <eager_stages
        <state
        <workdir
        <preloader
        <no_poll
        <resources
        job_count
        +settings
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

        <reload_state

        <observe
    },
);

sub init {
    my $self = shift;

    croak "You must specify a workdir or provide state"
        unless $self->{+STATE} || defined $self->{+WORKDIR};

    $self->{+WORKDIR} //= $self->{+STATE}->workdir;
    $self->{+STATE}   //= Test2::Harness::State->new(workdir => $self->{+WORKDIR});

    $self->{+JOB_COUNT} //= $self->settings->runner->job_count // 1;

    if (!$self->{+RESOURCES} || !@{$self->{+RESOURCES}}) {
        my $settings = $self->settings;
        my $resources = $self->{+RESOURCES} //= [];
        for my $res (@{$self->settings->runner->resources}) {
            require(mod2file($res));
            push @$resources => $res->new(settings => $self->settings, observe => $self->{+OBSERVE});
        }
    }

    unless (grep { $_->job_limiter } @{$self->{+RESOURCES}}) {
        require Test2::Harness::Runner::Resource::JobCount;
        push @{$self->{+RESOURCES}} => Test2::Harness::Runner::Resource::JobCount->new(job_count => $self->{+JOB_COUNT}, settings => $self->settings);
    }

    @{$self->{+RESOURCES}} = sort { $a->sort_weight <=> $b->sort_weight } @{$self->{+RESOURCES}};

    $self->{+DISPATCH_FILE} = Test2::Harness::Util::Queue->new(file => File::Spec->catfile($self->{+WORKDIR}, 'dispatch.jsonl'));

    $self->{+RELOAD_STATE} //= {};

    $self->poll;
}

sub settings {
    my $self = shift;
    return $self->{+SETTINGS} //= $self->state->settings;
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
    my ($stage) = @_;

    $self->poll();
    $self->clear_finished_run();

    while(1) {
        if (@{$self->{+PENDING_SPAWNS} //= []}) {
            my $spawn = shift @{$self->{+PENDING_SPAWNS}};
            next unless $spawn->{stage} eq $stage;
            $self->start_spawn($spawn);
            return $spawn;
        }

        my $task = shift @{$self->{+TASK_LIST}} or return undef;

        # If we are replaying a state then the task may have already completed,
        # so skip it if it is not in the running lookup.
        next unless $self->{+RUNNING_TASKS}->{$task->{job_id}};
        next unless $task->{stage} eq $stage;

        return $task;
    }
}

sub advance {
    my $self = shift;
    $self->poll();

    $_->tick() for @{$self->{+RESOURCES} //= []};

    $self->advance_run();
    return 0 unless $self->{+RUN};
    return 1 if $self->advance_tasks();
    return $self->clear_finished_run();
}

my %ACTIONS = (
    queue_run   => '_queue_run',
    queue_task  => '_queue_task',
    queue_spawn => '_queue_spawn',
    start_spawn => '_start_spawn',
    start_run   => '_start_run',
    start_task  => '_start_task',
    stop_run    => '_stop_run',
    stop_task   => '_stop_task',
    retry_task  => '_retry_task',
    stage_ready => '_stage_ready',
    stage_down  => '_stage_down',
    end_queue   => '_end_queue',
    halt_run    => '_halt_run',
    truncate    => '_truncate',
    reload      => '_reload',
);

sub poll {
    my $self = shift;

    return if $self->{+NO_POLL};

    my $queue = $self->dispatch_file;

    for my $item ($queue->poll) {
        my $data   = $item->[-1];
        my $item   = $data->{item};
        my $action = $data->{action};
        my $pid    = $data->{pid};

        my $sub = $ACTIONS{$action} or die "Invalid action '$action'";

        $self->$sub($item, $pid);
    }
}

sub _enqueue {
    my $self = shift;
    my ($action, $item) = @_;
    $self->{+DISPATCH_FILE}->enqueue({action => $action, item => $item, stamp => time, pid => $$});
    $self->poll;
}

sub truncate {
    my $self = shift;
    $self->halt_run($_) for keys %{$self->{+PENDING_TASKS} // {}};
    $self->_enqueue(truncate => $$);
    $self->poll;
}

sub _truncate { }

sub end_queue  { $_[0]->_enqueue('end_queue' => 1) }
sub _end_queue { $_[0]->{+QUEUE_ENDED} = 1 }

sub halt_run {
    my $self = shift;
    my ($run_id) = @_;
    $self->_enqueue(halt_run => $run_id);

    $self->state->transaction(w => sub {
        my ($state, $data) = @_;
        return unless exists $data->jobs->{$run_id};
        $data->jobs->{$run_id}->{closed} = 1;
    });
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
        state   => $self->{+STATE},
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
    die "$0 - Run stack mismatch, run start requested, but no pending runs to start" unless $run;
    die "$0 - Run stack mismatch, run-id does not match next pending run" unless $run->run_id eq $run_id;

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
    $spawn->{id} //= gen_uuid();
    $self->_enqueue(queue_spawn => $spawn);
}

sub _queue_spawn {
    my $self = shift;
    my ($spawn) = @_;

    $spawn->{id} //= gen_uuid();
    $spawn->{spawn} //= 1;
    $spawn->{use_preload} //= 1;

    $spawn->{stage} //= 'default';
    $spawn->{stage} = $self->task_stage($spawn);

    push @{$self->{+PENDING_SPAWNS}} => $spawn;

    return;
}

sub start_spawn {
    my $self = shift;
    my ($spec) = @_;
    $self->_enqueue(start_spawn => $spec);
}

sub _start_spawn {
    my $self = shift;
    my ($spec) = @_;

    my $uuid = $spec->{id} or die "Could not find UUID for spawn";

    @{$self->{+PENDING_SPAWNS}} = grep { $_->{id} ne $uuid } @{$self->{+PENDING_SPAWNS}};

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
    $self->_enqueue(start_task => $spec);
}

sub _start_task {
    my $self = shift;
    my ($spec) = @_;

    my $job_id    = $spec->{job_id} or die "No job_id provided";
    my $run_stage = $spec->{stage}  or die "No stage provided";
    my $res       = $spec->{res}    or die "No res provided";
    my $res_skip  = $spec->{resource_skip};

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

    $task->{resource_skip} = $res_skip if $res_skip;

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
    my ($stage, $pid) = @_;

    $self->{+STAGE_READINESS}->{$stage} = $pid // 1;

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

sub reload {
    my $self = shift;
    my ($stage, $data) = @_;
    $stage //= 'default';
    $self->_enqueue(reload => {%$data, stage => $stage});
    return;
}

sub _reload {
    my $self = shift;
    my ($data) = @_;

    my $stage    = $data->{stage};
    my $file     = $data->{file};
    my $success  = $data->{reloaded};
    my $error    = $data->{error};
    my $warnings = $data->{warnings};

    my $reload_state = $self->{+RELOAD_STATE} //= {};
    my $stage_state = $reload_state->{$stage} //= {};

    # It either succeeded, or the stage will be reloaded, no need to track brokenness
    if (defined $success) {
        delete $stage_state->{$file};
    }
    else {
        my $fields = {};
        $fields->{error} = $error if defined($error) && length($error);
        $fields->{warnings} = $warnings if $warnings && @{$warnings};

        if (keys %$fields) {
            $stage_state->{$file} = $fields;
        }
        else {
            delete $stage_state->{$file};
        }
    }

    return;
}

sub task_stage {
    my $self = shift;
    my ($task) = @_;

    my $wants = $task->{stage};
    $wants //= 'NOPRELOAD' unless $task->{use_preload};

    return $wants if $self->{+NO_POLL};

    return $wants // 'DEFAULT' unless $self->preloader;
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

    $cat = 'conflicts' if $cat eq 'general' && $task->{conflicts} && @{$task->{conflicts}};

    return ($run_id, $smoke, $stage, $cat, $dur);
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
    $self->{+STATE}->transaction(w => sub {
        my ($state, $data) = @_;
        return unless exists $data->jobs->{$run->run_id};
        $data->jobs->{$run->run_id}->{closed} = 1;
    });

    return 1;
}

sub advance_tasks {
    my $self = shift;

    for my $resource (@{$self->{+RESOURCES}}) {
        $resource->refresh();

        next unless $resource->job_limiter;
        return 0 if $resource->job_limiter_at_max();
    }

    my ($run_stage, $task, $res, %params) = $self->_next();

    my $out = 0;
    if ($task) {
        $out = 1;
        $self->start_task({job_id => $task->{job_id}, stage => $run_stage, res => $res, %params});
    }

    $_->discharge() for @{$self->{+RESOURCES}};

    return $out;
}

sub _cat_order {
    my $self = shift;

    my @cat_order = ('conflicts', 'general');

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

    my $max = 0;
    for my $resource (@{$self->resources}) {
        next unless $resource->job_limiter;
        my $val = $resource->job_limiter_max;
        $max = $val if !$max || $val < $max;
    }
    $max //= 1;

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

my %SORTED;
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

                    # Make sure anything with conflicts runs early.
                    unless ($SORTED{$search}++) {
                        @$search = sort { scalar(@{$b->{conflicts}}) <=> scalar(@{$a->{conflicts}}) } @$search;
                    }

                    for my $task (@$search) {
                        # If the job has a listed conflict and an existing job is running with that conflict, then pick another job.
                        next if first { $conflicts->{$_} } @{$task->{conflicts}};

                        my $ok = 1;
                        my @resource_skip;
                        for my $resource (@$resources) {
                            my $out = $resource->available($task) || 0; # normalize false to 0

                            push @resource_skip => ref($resource) || $resource if $out < 0;

                            $ok &&= $out;

                            # If we have a temporarily unavailable resource we
                            # skip, but if any resource is never avilable
                            # (skip) we want to finish the loop to add them all
                            # for the skip message.
                            last if !$ok && !@resource_skip;
                        }

                        # Some resource is temporarily not available
                        next unless $ok;

                        my $outres = {args => [], env_vars => {}, record => {}};

                        my @out = ($run_by_stage => $task, $outres);

                        my @record = @$resources;

                        if (@resource_skip) {
                            push @out => (resource_skip => \@resource_skip);

                            # Only the job limiter resources need to be recorded.
                            @record = grep { $_->job_limiter } @record;
                        }

                        for my $resource (@record) {
                            my $res = {args => [], env_vars => {}};
                            $resource->assign($task, $res);
                            push @{$outres->{args}} => @{$res->{args}};
                            $outres->{env_vars}->{$_} = $res->{env_vars}->{$_} for keys %{$res->{env_vars}};
                            $outres->{record}->{ref($resource)} = $res->{record};
                        }

                        return @out;
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
