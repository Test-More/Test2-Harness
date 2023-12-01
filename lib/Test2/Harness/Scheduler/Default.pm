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

    if (defined($update->{halt}) && $run->abort_on_bail) {
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

    my ($run, $job, $stage, $cat, $dur, $confl, $job_set, $skip, $resources) = $self->next_job() or return;

    my $res_id = $job->resource_id;

    my $ok;
    if ($skip) {
        @$resources = grep { $_->is_job_limiter } @$resources;
        my $env = {};
        $_->assign($res_id, $job, $env) for @$resources;
        $ok = $self->runner->skip_job($run, $job, $env, $skip);
    }
    else {
        my $env = {};
        $_->assign($res_id, $job, $env) for @$resources;
        $ok = $self->runner->launch_job($stage, $run, $job, $env);
    }

    # If the job could not be started
    unless ($ok) {
        $_->release($res_id, $job) for @$resources;
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

            $_->release($res_id, $job) for @{$resources};

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
            $resources = undef;
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

    my $resources = $self->{+RESOURCES};
    my $running   = $self->{+RUNNING};

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

                            JOB: for my $job_id (keys %$search) {
                                my $job = $search->{$job_id};

                                # Skip if conflicting tests are running
                                my $confl = $job->test_file->conflicts_list;
                                next if first { $running->{conflicts}->{$_} } @$confl;

                                my $res_id = $job->resource_id;

                                my $skip;
                                my @use_resources;
                                for my $res (@$resources) {
                                    next unless $res->applicable($res_id, $job);
                                    my $av = $res->available($res_id, $job);

                                    if ($av < 0) {
                                        my $comma = $skip ? 1 : 0;
                                        $skip //= "The following resources are permanently unavailable: ";
                                        $skip .= ', ' if $comma;
                                        $skip .= $res->resource_name;
                                        next;
                                    }

                                    next JOB unless $av || $skip;

                                    push @use_resources => $res;
                                }

                                delete $search->{$job_id};
                                return ($run, $job, $run_by_stage, $cat, $dur, $confl, $search, $skip, \@use_resources);
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

