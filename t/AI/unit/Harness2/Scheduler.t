use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::Scheduler;
use Test2::Harness2::RunStates;

use constant QUEUE_SLOT            => Test2::Harness2::Scheduler::QUEUE();
use constant SCHEDULER_SLOT        => Test2::Harness2::Scheduler::SCHEDULER();
use constant IN_FLIGHT_COUNT_SLOT  => Test2::Harness2::Scheduler::IN_FLIGHT_COUNT();
use constant BROKEN_RESOURCE_SLOT  => Test2::Harness2::Scheduler::BROKEN_RESOURCE_BEHAVIOR();

# --- fakes ---------------------------------------------------------------
{
    package SchTestJob;
    sub new {
        my ($c, %p) = @_;
        return bless { %p }, $c;
    }
    sub job_id   { $_[0]->{job_id} }
    sub job_try  { $_[0]->{job_try} // 1 }
}

{
    package SchTestRun;
    sub new {
        my ($c, %p) = @_;
        return bless { %p }, $c;
    }
    sub run_id    { $_[0]->{run_id} }
    sub jobs      { $_[0]->{jobs}      // [] }
    sub resources { $_[0]->{resources} // [] }
}

{
    package SchFakeJobTracker;
    sub new {
        my ($c, $h) = @_;
        return bless { harness => $h }, $c;
    }
    sub snapshot_run_results {
        my ($self, $run) = @_;
        return $self->{harness}->{snapshot_results}->{$run->run_id} // {};
    }
    sub emit_run_completed {
        my ($self, $run) = @_;
        push @{$self->{harness}->{emit_calls}}, $run;
        return;
    }
}

{
    package SchFakePreloadRouter;
    # Stand-in for Test2::Harness2::PreloadRouter. The scheduler only
    # ever calls ->resolve_for_job on it; no_preload keeps every job on
    # the direct-fork path.
    sub new { bless {}, $_[0] }
    sub resolve_for_job { return (undef, 'no_preload') }
}

{
    package SchFakeHarness;
    # Bare-minimum harness fake. The scheduler only ever reaches the
    # harness for launch glue (which the tests below intercept), for
    # ->resources (an empty arrayref is fine), and for ->job_tracker
    # (the run-finalization path on finalize_run_if_complete).
    sub new {
        my ($c, %p) = @_;
        my $self = bless {
            resources         => $p{resources} // [],
            ensure_calls      => [],
            launch_calls      => [],
            emit_calls        => [],
            teardown_calls    => [],
            snapshot_results  => {},
            run_state         => 'running',
            finish_after      => 0,
            preload_router    => SchFakePreloadRouter->new,
        }, $c;
        $self->{job_tracker} = SchFakeJobTracker->new($self);
        return $self;
    }
    sub resources                   { $_[0]->{resources} }
    sub job_tracker                 { $_[0]->{job_tracker} }
    sub preload_router              { $_[0]->{preload_router} }
    sub _ensure_run_service_started { push @{$_[0]->{ensure_calls}},   $_[1] }
    sub _launch_job                 { push @{$_[0]->{launch_calls}}, [@_[1..$#_]] }
    sub _write_run_report           { }
    sub _teardown_run_service       { push @{$_[0]->{teardown_calls}}, $_[1] }
    sub emit_service_event          { }
}

# Reach into the harness's hash for STATE / FINISH_AFTER_INITIAL_RUN
# the way the scheduler does: by string key. The fake stores those
# under the same constant names so the lookup succeeds.
require Test2::Harness2;
sub _seed_state {
    my ($h, $state) = @_;
    $h->{Test2::Harness2::STATE()} = $state;
}

# Caller MUST hold the returned harness alive: Role::Subsystem weakens
# the scheduler's backref, so a local lexical going out of scope in a
# factory function would clear it and the scheduler's harness() would
# return undef inside handle_broken_resource et al. Each test
# stashes the harness in its own lexical via SCHED_HARNESS_HOLDERS.
our @SCHED_HARNESS_HOLDERS;

sub mk_scheduler {
    my (%p) = @_;
    my $rs        = $p{run_states} // Test2::Harness2::RunStates->new;
    my $pid_index = $p{pid_index}  // bless {}, 'SchFakePid';
    my $h         = $p{harness}    // SchFakeHarness->new;
    _seed_state($h, 'running');
    push @SCHED_HARNESS_HOLDERS, $h;
    return Test2::Harness2::Scheduler->new(
        harness    => $h,
        run_states => $rs,
        pid_index  => $pid_index,
        (defined $p{broken_resource_behavior} ? (broken_resource_behavior => $p{broken_resource_behavior}) : ()),
    );
}

# --- init / validation ---------------------------------------------------
subtest defaults => sub {
    my $sch = mk_scheduler();
    is($sch->{+QUEUE_SLOT}, [], 'queue defaults empty');
    is($sch->{+SCHEDULER_SLOT}, {}, 'scheduler table defaults empty');
    is($sch->{+IN_FLIGHT_COUNT_SLOT}, 0, 'in-flight defaults zero');
    is($sch->{+BROKEN_RESOURCE_SLOT}, 'skip', 'broken_resource defaults to skip');
};

subtest broken_resource_validation => sub {
    my $h = SchFakeHarness->new;
    _seed_state($h, 'running');
    my $rs = Test2::Harness2::RunStates->new;
    my $pi = bless {}, 'SchFakePid';

    my $ok = eval {
        Test2::Harness2::Scheduler->new(
            harness                  => $h,
            run_states               => $rs,
            pid_index                => $pi,
            broken_resource_behavior => 'bogus',
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'bogus broken_resource_behavior rejected');
    like($err, qr/invalid broken_resource_behavior 'bogus'/, 'error mentions value');

    for my $b (qw/skip fail abort/) {
        my $s = eval {
            Test2::Harness2::Scheduler->new(
                harness                  => $h,
                run_states               => $rs,
                pid_index                => $pi,
                broken_resource_behavior => $b,
            );
        };
        ok($s, "'$b' accepted") or diag $@;
    }
};

subtest required_args => sub {
    my $rs = Test2::Harness2::RunStates->new;
    my $pi = bless {}, 'SchFakePid';
    my $h  = SchFakeHarness->new;

    my $ok;
    $ok = eval { Test2::Harness2::Scheduler->new(run_states => $rs, pid_index => $pi); 1 };
    ok(!$ok, "'harness' required");
    like($@, qr/'harness' is required/);

    $ok = eval { Test2::Harness2::Scheduler->new(harness => $h, pid_index => $pi); 1 };
    ok(!$ok, "'run_states' required");
    like($@, qr/'run_states' is required/);

    $ok = eval { Test2::Harness2::Scheduler->new(harness => $h, run_states => $rs); 1 };
    ok(!$ok, "'pid_index' required");
    like($@, qr/'pid_index' is required/);
};

# --- queue helpers -------------------------------------------------------
subtest queue_roundtrip => sub {
    my $sch = mk_scheduler();
    my $run = SchTestRun->new(run_id => 'r-1', jobs => []);

    $sch->enqueue($run);
    is($sch->queue, [$run], 'enqueue appends');
    ok($sch->run_in_queue('r-1'), 'run_in_queue=1 for queued run');
    ok(!$sch->run_in_queue('r-other'), 'run_in_queue=0 for unknown');
    is($sch->run_by_id('r-1'), $run, 'run_by_id returns the run');
    is($sch->run_by_id('nope'), undef, 'run_by_id undef for unknown');

    my @dropped = $sch->remove_from_queue('r-1');
    is(\@dropped, [$run], 'remove_from_queue returns dropped run');
    is($sch->queue, [], 'queue empty after remove');

    $sch->enqueue($run);
    $sch->clear_queue;
    is($sch->queue, [], 'clear_queue empties');
};

# --- scheduler table state transitions -----------------------------------
subtest state_transitions => sub {
    my $sch = mk_scheduler();
    my $job_a = SchTestJob->new(job_id => 'j-a');
    my $job_b = SchTestJob->new(job_id => 'j-b');
    my $run   = SchTestRun->new(run_id => 'r-x', jobs => [$job_a, $job_b]);

    $sch->queue_run($run);
    is($sch->pending_for_run('r-x'), ['j-a', 'j-b'], 'both jobs pending');
    ok(!$sch->started('r-x'), 'not yet started');
    ok(!$sch->is_running('r-x', 'j-a'), 'j-a not yet running');
    ok(!$sch->run_complete('r-x'), 'not complete (pending nonempty)');

    $sch->mark_running('r-x', 'j-a');
    is($sch->pending_for_run('r-x'), ['j-b'], 'j-a removed from pending');
    ok($sch->is_running('r-x', 'j-a'), 'j-a now running');
    ok($sch->started('r-x'), 'started flag set');

    $sch->mark_done('r-x', 'j-a');
    ok(!$sch->is_running('r-x', 'j-a'), 'j-a no longer running');
    ok(!$sch->run_complete('r-x'), 'still pending j-b');

    $sch->mark_running('r-x', 'j-b');
    $sch->mark_done('r-x', 'j-b');
    ok($sch->run_complete('r-x'), 'run_complete=1 once started+drained');

    $sch->drop_run('r-x');
    ok($sch->run_complete('r-x'), 'dropped run reports complete');
};

subtest mark_pending_restores_job => sub {
    my $sch = mk_scheduler();
    my $job = SchTestJob->new(job_id => 'j-1');
    my $run = SchTestRun->new(run_id => 'r-p', jobs => [$job]);
    $sch->queue_run($run);
    $sch->mark_running('r-p', 'j-1');
    is($sch->pending_for_run('r-p'), [], 'pending drained');

    $sch->mark_pending('r-p', 'j-1');
    is($sch->pending_for_run('r-p'), ['j-1'], 'job back in pending');
    ok(!$sch->is_running('r-p', 'j-1'), 'no longer running');

    # Idempotent: calling mark_pending again is a no-op.
    $sch->mark_pending('r-p', 'j-1');
    is($sch->pending_for_run('r-p'), ['j-1'], 'still single entry');
};

subtest skip_removes_pending_and_started => sub {
    my $sch = mk_scheduler();
    my $job = SchTestJob->new(job_id => 'j-s');
    my $run = SchTestRun->new(run_id => 'r-s', jobs => [$job]);
    $sch->queue_run($run);
    ok(!$sch->started('r-s'), 'not yet started');

    $sch->skip('r-s', 'j-s');
    is($sch->pending_for_run('r-s'), [], 'pending drained by skip');
    ok($sch->started('r-s'), 'started flag set by skip');
    ok($sch->run_complete('r-s'), 'skip closes out the run');
};

subtest snapshot => sub {
    my $sch = mk_scheduler();
    my $job = SchTestJob->new(job_id => 'j-snap');
    my $run = SchTestRun->new(run_id => 'r-snap', jobs => [$job]);
    $sch->queue_run($run);
    $sch->mark_running('r-snap', 'j-snap');

    my $snap = $sch->snapshot('r-snap');
    is($snap->{pending}, [],           'snapshot pending empty');
    is($snap->{running}, ['j-snap'],   'snapshot running has the job');
    ok($snap->{started},                'snapshot started flag set');

    is($sch->snapshot('nonexistent'), undef, 'snapshot undef for unknown run');
};

# --- in-flight counter ---------------------------------------------------
subtest in_flight_arithmetic => sub {
    my $sch = mk_scheduler();
    is($sch->in_flight_count, 0, 'starts at 0');
    $sch->inc_in_flight;
    $sch->inc_in_flight;
    is($sch->in_flight_count, 2, 'two increments');
    $sch->dec_in_flight;
    is($sch->in_flight_count, 1, 'one decrement');
    $sch->reset_in_flight_count;
    is($sch->in_flight_count, 0, 'reset clears');

    # Scalar ref derefs to the live value.
    my $ref = $sch->in_flight_ref;
    is($$ref, 0, 'ref derefs to 0');
    $sch->inc_in_flight;
    is($$ref, 1, 'ref reflects mutation');
};

# --- try_launch_next via mocked launch glue -----------------------------
subtest try_launch_next_with_no_resources => sub {
    my $h   = SchFakeHarness->new;
    _seed_state($h, 'running');
    my $rs  = Test2::Harness2::RunStates->new;
    my $sch = Test2::Harness2::Scheduler->new(
        harness => $h, run_states => $rs, pid_index => bless({}, 'SchFakePid'),
    );

    my $job = SchTestJob->new(job_id => 'j-1');
    my $run = SchTestRun->new(run_id => 'r-1', jobs => [$job]);
    $rs->set_state($run->run_id, Test2::Harness2::Run::State->new(
        run_id  => 'r-1',
        pending => ['j-1'],
    ));

    $sch->enqueue($run);
    $sch->queue_run($run);

    my $launched = $sch->try_launch_next;
    ok($launched, 'try_launch_next returned truthy');
    is(scalar @{$h->{launch_calls}}, 1, 'harness->_launch_job called once');
    is($h->{launch_calls}->[0]->[0], $run, 'first arg is run');
    is($h->{launch_calls}->[0]->[1], $job, 'second arg is job');
    is(scalar @{$h->{ensure_calls}}, 1, 'ensure_run_service_started invoked');
};

subtest try_launch_next_skips_complete_runs => sub {
    require Test2::Harness2::Run::State;
    my $sch = mk_scheduler();
    my $h   = $sch->harness;
    my $rs  = $sch->{Test2::Harness2::Scheduler::RUN_STATES()};

    my $job = SchTestJob->new(job_id => 'j-2');
    my $run = SchTestRun->new(run_id => 'r-2', jobs => [$job]);
    $rs->set_state('r-2', Test2::Harness2::Run::State->new(run_id => 'r-2', pending => ['j-2']));

    $sch->enqueue($run);
    $sch->queue_run($run);

    # Pretend the job already finished from the scheduler's perspective.
    $sch->mark_running('r-2', 'j-2');
    $sch->mark_done('r-2', 'j-2');

    is($sch->try_launch_next, 0, 'no launch when scheduler thinks run is complete');
    is(scalar @{$h->{launch_calls}}, 0, 'harness->_launch_job not called');
};

# --- broken_resource paths ---------------------------------------------
# Fake resource that responds to needed/is_permanent_broken with values
# the scheduler will consult. Enough to drive handle_broken_resource +
# launch_unavailable_action through their branches.
{
    package SchBrokenRes;
    sub new {
        my ($c, %p) = @_;
        return bless { %p }, $c;
    }
    sub resource_name      { $_[0]->{name} // 'broken' }
    sub is_permanent_broken { $_[0]->{permanent} ? 1 : 0 }
    sub needed             { 1 }
    sub available          { 1 }
}

subtest handle_broken_resource_skip => sub {
    my $sch = mk_scheduler();
    my $h   = $sch->harness;

    my $job = SchTestJob->new(job_id => 'jb-skip');
    my $run = SchTestRun->new(run_id => 'rb-skip', jobs => [$job], resources => []);
    $sch->enqueue($run);
    $sch->queue_run($run);

    my $outcome = $sch->handle_broken_resource($run, $job, 'BrokenResource');
    is($outcome, 'launched', 'skip-path launches the unavailable-action job');
    is(scalar @{$h->{launch_calls}}, 1, 'one launch issued');
    # _launch_job is called with launch + assign_args keys for skip launches.
    my @args = @{$h->{launch_calls}->[0]};
    my %opts = @args[3..$#args];
    is(ref($opts{launch}), 'ARRAY', 'launch command was passed');
    like($opts{launch}->[3], qr/skip_all/, 'launch one-liner calls skip_all');
};

subtest handle_broken_resource_fail => sub {
    my $sch = mk_scheduler(broken_resource_behavior => 'fail');
    my $h   = $sch->harness;

    my $job = SchTestJob->new(job_id => 'jb-fail');
    my $run = SchTestRun->new(run_id => 'rb-fail', jobs => [$job], resources => []);
    $sch->enqueue($run);
    $sch->queue_run($run);

    my $outcome = $sch->handle_broken_resource($run, $job, 'BrokenRes');
    is($outcome, 'launched', 'fail-path launches');
    my @args = @{$h->{launch_calls}->[0]};
    my %opts = @args[3..$#args];
    like($opts{launch}->[3], qr/\Adie /, 'launch one-liner dies');
};

subtest handle_broken_resource_abort_latches_reason => sub {
    require Test2::Harness2::Run::State;
    my $sch = mk_scheduler(broken_resource_behavior => 'abort');
    my $h   = $sch->harness;
    my $rs  = $sch->{Test2::Harness2::Scheduler::RUN_STATES()};

    my $job = SchTestJob->new(job_id => 'jb-abort');
    my $run = SchTestRun->new(run_id => 'rb-abort', jobs => [$job], resources => []);
    $rs->set_state('rb-abort', Test2::Harness2::Run::State->new(run_id => 'rb-abort', pending => ['jb-abort']));
    $sch->enqueue($run);
    $sch->queue_run($run);

    my $outcome = $sch->handle_broken_resource($run, $job, 'BrokenRes');
    is($outcome, 'launched', 'abort-path launches the trigger job');

    my $rstate = $rs->state('rb-abort');
    is($rstate->aborted_reason, 'BrokenRes', 'aborted_reason latched on run state');
};

done_testing;
