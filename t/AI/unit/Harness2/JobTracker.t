use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::JobTracker;
use Test2::Harness2::RunStates;
use Test2::Harness2::Run::State;

use constant RUNNING_JOBS_SLOT
    => Test2::Harness2::JobTracker::RUNNING_JOBS();
use constant PENDING_SYNTH_SLOT
    => Test2::Harness2::JobTracker::PENDING_SYNTH_COMPLETIONS();

# --- fake collaborators --------------------------------------------------
{
    package JTFakeJob;
    sub new      { my ($c, %p) = @_; bless { %p }, $c }
    sub job_id   { $_[0]->{job_id} }
    sub job_try  { $_[0]->{job_try} // 1 }
    sub test_file {
        my $self = shift;
        return $self->{test_file} //= bless { abs => $self->{abs} }, 'JTFakeTF';
    }
}

{
    package JTFakeTF;
    sub absolute { $_[0]->{abs} }
}

{
    package JTFakeRun;
    sub new       { my ($c, %p) = @_; bless { %p }, $c }
    sub run_id    { $_[0]->{run_id} }
    sub jobs      { $_[0]->{jobs} // [] }
}

{
    package JTFakePid;
    sub new { bless { calls => [] }, shift }
    sub register {
        my ($self, @args) = @_;
        push @{$self->{calls}}, ['register', @args];
        return;
    }
    sub forget {
        my ($self, @args) = @_;
        push @{$self->{calls}}, ['forget', @args];
        return;
    }
}

{
    package JTFakeScheduler;
    sub new {
        my $c = shift;
        return bless {
            in_flight => 0,
            done      => [],
            finalized => [],
        }, $c;
    }
    sub inc_in_flight { $_[0]->{in_flight}++; return $_[0] }
    sub dec_in_flight { $_[0]->{in_flight}--; return $_[0] }
    sub mark_done {
        my ($self, $rid, $jid) = @_;
        push @{$self->{done}}, [$rid, $jid];
    }
    sub finalize_run_if_complete {
        my ($self, $run) = @_;
        push @{$self->{finalized}}, $run ? $run->run_id : undef;
    }
}

{
    package JTFakeBroadcaster;
    sub new { bless { broadcasts => [] }, shift }
    sub broadcast_run_state {
        my ($self, $rid) = @_;
        push @{$self->{broadcasts}}, $rid;
    }
}

{
    package JTFakePreloadRouter;
    # Minimal preload-router fake: only the bareword hash slot
    # JobTracker reaches for via $h->preload_router->{...}.
    sub new {
        my ($c, %p) = @_;
        return bless { pending_spawn_requests => $p{pending_spawn_requests} // {} }, $c;
    }
}

{
    package JTFakeHarness;
    # Minimal harness fake: the job tracker reaches the harness for
    # emit_service_event (recorded), and through preload_router for
    # pending_spawn_requests (now living on the preload-router
    # subsystem). EMITTER is intentionally absent so the
    # collector-start / collector-end reflectors are silent no-ops in
    # the simple cases.
    sub new {
        my ($c, %p) = @_;
        return bless {
            events                 => [],
            preload_router         => JTFakePreloadRouter->new(
                pending_spawn_requests => $p{pending_spawn_requests} // {},
            ),
            collector_grace_secs   => $p{collector_grace_secs} // 10,
            emitter                => $p{emitter},
        }, $c;
    }
    sub emit_service_event {
        my ($self, %fields) = @_;
        push @{$self->{events}}, \%fields;
    }
    sub preload_router { $_[0]->{preload_router} }
}

{
    package JTFakeResource;
    sub new {
        my ($c, %p) = @_;
        bless { name => $p{name} // 'r', released => [] }, $c;
    }
    sub resource_name { $_[0]->{name} }
    sub release {
        my ($self, %args) = @_;
        push @{$self->{released}}, \%args;
        return 1;
    }
}

# Caller MUST hold the returned harness alive; Role::Subsystem weakens
# the job tracker's backref.
our @JT_HOLDERS;
sub mk_job_tracker {
    my (%p) = @_;
    my $rs  = $p{run_states}  // Test2::Harness2::RunStates->new;
    my $pi  = $p{pid_index}   // JTFakePid->new;
    my $sc  = $p{scheduler}   // JTFakeScheduler->new;
    my $bc  = $p{broadcaster} // JTFakeBroadcaster->new;
    my $h   = $p{harness}     // JTFakeHarness->new;
    push @JT_HOLDERS, $h;
    return (
        Test2::Harness2::JobTracker->new(
            harness     => $h,
            run_states  => $rs,
            pid_index   => $pi,
            scheduler   => $sc,
            broadcaster => $bc,
        ),
        {harness => $h, run_states => $rs, pid_index => $pi, scheduler => $sc, broadcaster => $bc},
    );
}

# --- init / required args ------------------------------------------------
subtest defaults => sub {
    my ($jt) = mk_job_tracker();
    is($jt->{+RUNNING_JOBS_SLOT}, {}, 'running_jobs defaults empty');
    is($jt->{+PENDING_SYNTH_SLOT}, {}, 'pending_synth_completions defaults empty');
    is($jt->running_jobs, {}, 'running_jobs accessor');
    is($jt->pending_synth_completions, {}, 'pending_synth_completions accessor');
};

subtest required_args => sub {
    my $rs = Test2::Harness2::RunStates->new;
    my $pi = JTFakePid->new;
    my $sc = JTFakeScheduler->new;
    my $bc = JTFakeBroadcaster->new;
    my $h  = JTFakeHarness->new;

    my $ok;
    $ok = eval { Test2::Harness2::JobTracker->new(run_states => $rs, pid_index => $pi, scheduler => $sc, broadcaster => $bc); 1 };
    ok(!$ok, "'harness' required");
    like($@, qr/'harness' is required/);

    $ok = eval { Test2::Harness2::JobTracker->new(harness => $h, pid_index => $pi, scheduler => $sc, broadcaster => $bc); 1 };
    ok(!$ok, "'run_states' required");
    like($@, qr/'run_states' is required/);

    $ok = eval { Test2::Harness2::JobTracker->new(harness => $h, run_states => $rs, scheduler => $sc, broadcaster => $bc); 1 };
    ok(!$ok, "'pid_index' required");
    like($@, qr/'pid_index' is required/);

    $ok = eval { Test2::Harness2::JobTracker->new(harness => $h, run_states => $rs, pid_index => $pi, broadcaster => $bc); 1 };
    ok(!$ok, "'scheduler' required");
    like($@, qr/'scheduler' is required/);

    $ok = eval { Test2::Harness2::JobTracker->new(harness => $h, run_states => $rs, pid_index => $pi, scheduler => $sc); 1 };
    ok(!$ok, "'broadcaster' required");
    like($@, qr/'broadcaster' is required/);
};

# --- handle_collector_start / handle_collector_end ----------------------
subtest collector_start_end => sub {
    # No emitter: silent no-op.
    my ($jt) = mk_job_tracker();
    ok(lives { $jt->handle_collector_start({foo => 1}) }, 'no-op without emitter');
    ok(lives { $jt->handle_collector_end({foo => 1})   }, 'no-op without emitter (end)');

    # With emitter: emit_raw called with the right facet.
    my @raw;
    my $emitter = bless { raw => \@raw }, 'JTFakeEmitter';
    {
        no warnings 'redefine';
        *JTFakeEmitter::emit_raw = sub {
            my ($self, $event) = @_;
            push @{$self->{raw}}, $event;
        };
    }
    my $h = JTFakeHarness->new(emitter => $emitter);
    push @JT_HOLDERS, $h;
    my ($jt2) = mk_job_tracker(harness => $h);

    $jt2->handle_collector_start({k => 'v'});
    is(scalar @raw, 1, 'collector_start emit_raw called once');
    ok($raw[0]{facet_data}{harness_collector_start}, 'top-level harness_collector_start facet');
    is($raw[0]{facet_data}{harness_collector_start}{k}, 'v', 'content forwarded');

    @raw = ();
    $jt2->handle_collector_end({k => 'v2'});
    is(scalar @raw, 1, 'collector_end emit_raw called once');
    ok($raw[0]{facet_data}{harness_collector_end}, 'top-level harness_collector_end facet');
};

# --- handle_test_job_started -> mark_running + broadcast ----------------
subtest test_job_started => sub {
    my ($jt, $deps) = mk_job_tracker();

    $jt->handle_test_job_started({
        run_id  => 'r1',
        job_id  => 'j1',
        job_try => 1,
        stamp   => 1000,
    });

    my $rstate = $deps->{run_states}->state('r1');
    ok($rstate, 'run state lazily created');
    is($rstate->running, ['j1'], 'job marked running');

    is(scalar @{$deps->{harness}{events}}, 1, 'one job_started event emitted');
    is($deps->{harness}{events}[0]{kind}, 'job_started', 'kind=job_started');

    is($deps->{broadcaster}{broadcasts}, ['r1'], 'broadcast for run');
};

subtest test_job_started_preload_placeholder => sub {
    my ($jt, $deps) = mk_job_tracker();
    # Preload placeholder install.
    $jt->set_running_job('j1', {
        run                  => JTFakeRun->new(run_id => 'r1'),
        job                  => JTFakeJob->new(job_id => 'j1'),
        pid                  => undef,
        awaiting_preload_pid => 1,
    });
    $deps->{harness}->preload_router->{pending_spawn_requests}{"r1\0j1"} = {x => 1};

    $jt->handle_test_job_started({
        run_id        => 'r1',
        job_id        => 'j1',
        collector_pid => 4242,
        job_try       => 1,
        stamp         => 2000,
    });

    my $cur = $jt->running_jobs->{j1};
    is($cur->{pid}, 4242, 'pid filled in from collector_pid');
    ok(!exists $cur->{awaiting_preload_pid}, 'placeholder flag cleared');

    my @calls = grep { $_->[0] eq 'register' } @{$deps->{pid_index}{calls}};
    is(scalar @calls, 1, 'pid registered with PidIndex');

    ok(!exists $deps->{harness}->preload_router->{pending_spawn_requests}{"r1\0j1"},
        'pending spawn request dropped from preload router');
};

# --- handle_test_job_completed -> mark_done + flags + broadcast --------
subtest test_job_completed => sub {
    my ($jt, $deps) = mk_job_tracker();

    $jt->handle_test_job_completed({
        run_id  => 'r2',
        job_id  => 'j2',
        job_try => 1,
        pass    => 1,
        exit    => 0,
        stamp   => 3000,
    });

    my $flags = $deps->{run_states}->flags_peek('r2');
    ok($flags->{completed_job_ids}{j2}, 'completed_job_ids latched');
    ok($flags->{completed_job_states}{j2}, 'completed_job_states snapshotted');

    my $rstate = $deps->{run_states}->state('r2');
    is($rstate->done, ['j2'], 'job marked done');

    # Idempotent: second call is a no-op.
    my $events_n = scalar @{$deps->{harness}{events}};
    $jt->handle_test_job_completed({
        run_id => 'r2', job_id => 'j2', pass => 1, exit => 0,
    });
    is(scalar @{$deps->{harness}{events}}, $events_n, 'no extra events on dup');
};

subtest test_job_completed_failing_latch => sub {
    my ($jt, $deps) = mk_job_tracker();

    $jt->handle_test_job_completed({
        run_id  => 'r3',
        job_id  => 'jf',
        job_try => 1,
        pass    => 0,
        exit    => 1,
        stamp   => 4000,
    });

    my @run_failing = grep { $_->{kind} eq 'run_failing' } @{$deps->{harness}{events}};
    is(scalar @run_failing, 1, 'run_failing latched once for first fail');

    my $flags = $deps->{run_states}->flags_peek('r3');
    is($flags->{failing_emitted}, 1, 'failing_emitted set');
    is($flags->{pass},            0, 'pass cleared');
};

# --- emit_run_completed -------------------------------------------------
subtest emit_run_completed => sub {
    # With emitter: emit_raw fires with harness.run_completed + collector_report.
    my @raw;
    my $emitter = bless { raw => \@raw }, 'JTFakeEmitter';
    {
        no warnings 'redefine';
        *JTFakeEmitter::emit_raw = sub {
            push @{$_[0]->{raw}}, $_[1];
        };
    }
    my $h = JTFakeHarness->new(emitter => $emitter);
    push @JT_HOLDERS, $h;
    my ($jt, $deps) = mk_job_tracker(harness => $h);

    # Seed flags so emit_run_completed has something to summarize.
    my $flags = $deps->{run_states}->flags('rec');
    $flags->{pass}                       = 1;
    $flags->{started_at}                 = 1;
    $flags->{ended_at}                   = 2;
    $flags->{completed_job_states}{jp}   = {pass => 1, job_try => 1};

    my $run = JTFakeRun->new(run_id => 'rec', jobs => []);
    $jt->emit_run_completed($run);

    is(scalar @raw, 1, 'emit_raw fired');
    ok($raw[0]{facet_data}{harness}{run_completed}, 'run_completed facet present');
    ok($raw[0]{facet_data}{collector_report},       'collector_report facet present');
    is($raw[0]{facet_data}{collector_report}{total_jobs}, 1, 'one job in report');

    # Idempotent: second call no-op.
    $jt->emit_run_completed($run);
    is(scalar @raw, 1, 'emit_run_completed idempotent per run');
};

# --- snapshot_run_results -----------------------------------------------
subtest snapshot_run_results => sub {
    my ($jt, $deps) = mk_job_tracker();

    # Seed run state with both completed and not-yet-completed jobs.
    my $rstate = Test2::Harness2::Run::State->new(run_id => 'rss');
    $deps->{run_states}->set_state('rss', $rstate);
    $rstate->seed_job_result('jdone', started_at => 1);
    $rstate->record_job_result('jdone', pass => 1, completed_at => 2);
    $rstate->seed_job_result('jpending', started_at => 1);

    my $run = JTFakeRun->new(run_id => 'rss');
    my $snap = $jt->snapshot_run_results($run);
    is($snap->{run_id}, 'rss',     'run_id carried');
    is($snap->{state},  'complete','state=complete');
    is($snap->{pass},   1,         'pass=1 when only completed jobs passed');

    # Failing completed job flips pass.
    $rstate->seed_job_result('jfail', started_at => 1);
    $rstate->record_job_result('jfail', pass => 0, completed_at => 3);
    my $snap2 = $jt->snapshot_run_results($run);
    is($snap2->{pass}, 0, 'pass=0 when any completed job failed');
};

# --- handle_job_release -------------------------------------------------
subtest handle_job_release => sub {
    my ($jt, $deps) = mk_job_tracker();

    my $run = JTFakeRun->new(run_id => 'rrel');
    my $res = JTFakeResource->new(name => 'r');
    $jt->set_running_job('jrel', {
        run                => $run,
        job                => JTFakeJob->new(job_id => 'jrel'),
        pid                => 12345,
        assigned_resources => [$res],
        assign_id          => 'AID',
    });
    $deps->{scheduler}->inc_in_flight;

    $jt->handle_job_release({job_id => 'jrel'});

    ok(!exists $jt->running_jobs->{jrel}, 'running_jobs entry dropped');
    is($deps->{scheduler}{in_flight}, 0, 'in_flight decremented');
    is($deps->{scheduler}{done}, [['rrel', 'jrel']], 'scheduler mark_done called');
    is($deps->{scheduler}{finalized}, ['rrel'], 'scheduler finalize_run_if_complete called');
    is(scalar @{$res->{released}}, 1, 'resource released');
    is($res->{released}[0]{id}, 'AID', 'release id matches assign id');

    # Unknown job id is a silent no-op.
    ok(lives { $jt->handle_job_release({job_id => 'missing'}) }, 'unknown job no-op');
};

# --- handle_collector_exit + race ---------------------------------------
subtest handle_collector_exit_race => sub {
    # CASE A: test_job_completed already arrived -> just clear pid index.
    {
        my ($jt, $deps) = mk_job_tracker();
        my $run = JTFakeRun->new(run_id => 'race-A');
        $jt->set_running_job('jra', {
            run => $run,
            job => JTFakeJob->new(job_id => 'jra'),
            pid => 9001,
        });
        my $flags = $deps->{run_states}->flags('race-A');
        $flags->{completed_job_ids}{jra} = 1;

        my $handled = $jt->handle_collector_exit(9001, 0);
        ok($handled, 'collector exit handled');
        my @forgets = grep { $_->[0] eq 'forget' } @{$deps->{pid_index}{calls}};
        is(scalar @forgets, 1, 'pid_index forget called');
        ok(!exists $jt->pending_synth_completions->{jra}, 'no synth-completion armed when completed first');
    }

    # CASE B: test_job_completed has NOT arrived -> arm synth grace entry.
    {
        my ($jt) = mk_job_tracker();
        my $run = JTFakeRun->new(run_id => 'race-B');
        $jt->set_running_job('jrb', {
            run => $run,
            job => JTFakeJob->new(job_id => 'jrb', job_try => 1),
            pid => 9002,
        });

        my $handled = $jt->handle_collector_exit(9002, 137);
        ok($handled, 'collector exit handled');
        my $entry = $jt->pending_synth_completions->{jrb};
        ok($entry, 'pending synth-completion armed');
        is($entry->{pid},              9002, 'pid recorded');
        is($entry->{raw_exit_on_reap}, 137,  'raw exit captured');
        is($entry->{run_id},           'race-B', 'run_id captured');
        ok($entry->{pid_gone_at}, 'pid_gone_at stamped');

        # Running-job entry stays in place (watchdog will claim it).
        ok($jt->running_jobs->{jrb}, 'running_jobs entry retained for watchdog');
    }

    # CASE C: unknown pid -> returns 0 so the harness's run_on_pid falls
    # through to the next handler.
    {
        my ($jt) = mk_job_tracker();
        my $handled = $jt->handle_collector_exit(99999, 0);
        ok(!$handled, 'unknown pid not handled');
    }
};

# --- check_synth_completions grace window -------------------------------
subtest check_synth_completions_grace => sub {
    my ($jt, $deps) = mk_job_tracker();
    $deps->{harness}{collector_grace_secs} = 5;

    my $run = JTFakeRun->new(run_id => 'rg');
    $jt->set_running_job('jg', {
        run => $run,
        job => JTFakeJob->new(job_id => 'jg', job_try => 1),
        pid => 5151,
        assigned_resources => [JTFakeResource->new(name => 'rrr')],
        assign_id          => 'AID',
    });
    $deps->{scheduler}->inc_in_flight;

    # Arm the synth entry. pid_gone_at is fresh so the grace window
    # has not yet expired.
    $jt->pending_synth_completions->{jg} = {
        run_id           => 'rg',
        job_id           => 'jg',
        job_try          => 1,
        pid              => 5151,
        pid_gone_at      => time,
        raw_exit_on_reap => 99,
    };

    # First tick: grace not yet expired -> no synth, entry preserved.
    $jt->check_synth_completions;
    ok(exists $jt->pending_synth_completions->{jg}, 'entry retained while in grace window');
    ok(exists $jt->running_jobs->{jg},              'running_jobs entry retained');

    # Backdate pid_gone_at past the grace window. Suppress the synth warn
    # so it doesn't pollute test output.
    $jt->pending_synth_completions->{jg}{pid_gone_at} = time - 60;
    local $SIG{__WARN__} = sub { };
    $jt->check_synth_completions;
    ok(!exists $jt->pending_synth_completions->{jg}, 'synth entry dropped after grace');
    ok(!exists $jt->running_jobs->{jg},              'running_jobs cleared by synth path');

    my $flags = $deps->{run_states}->flags_peek('rg');
    ok($flags->{completed_job_ids}{jg}, 'completed_job_ids latched via synth');
    my $st = $flags->{completed_job_states}{jg};
    is($st->{pass},  0, 'synth recorded as failure');
    is($st->{synth}, 1, 'synth marker present');
    is($st->{exit},  99, 'raw exit recorded');

    # Scheduler bookkeeping: dec_in_flight + mark_done + finalize.
    is($deps->{scheduler}{in_flight}, 0, 'in_flight decremented by orphan release');
    my @done_for_jg = grep { $_->[0] eq 'rg' && $_->[1] eq 'jg' } @{$deps->{scheduler}{done}};
    ok(scalar(@done_for_jg), 'scheduler mark_done called for orphan');
    my @finalized_rg = grep { defined && $_ eq 'rg' } @{$deps->{scheduler}{finalized}};
    ok(scalar(@finalized_rg), 'scheduler finalize_run_if_complete called for orphan');
};

# --- check_synth_completions cancels when completion arrives ------------
subtest check_synth_completions_real_completed_first => sub {
    my ($jt, $deps) = mk_job_tracker();

    my $run = JTFakeRun->new(run_id => 'rc');
    $jt->set_running_job('jc', {
        run => $run,
        job => JTFakeJob->new(job_id => 'jc'),
        pid => 7777,
    });

    $jt->pending_synth_completions->{jc} = {
        run_id      => 'rc',
        job_id      => 'jc',
        pid         => 7777,
        pid_gone_at => time - 100,    # already past grace
    };

    # Stuff a completed_job_ids entry so the watchdog cancels the synth.
    my $flags = $deps->{run_states}->flags('rc');
    $flags->{completed_job_ids}{jc} = 1;

    $jt->check_synth_completions;
    ok(!exists $jt->pending_synth_completions->{jc},
        'pending synth dropped when real completion arrived inside grace');
    # No synth fields added because handle_test_job_completed was never called.
    ok(!exists $flags->{completed_job_states}{jc},
        'no synth state added when real completion arrived');
};

done_testing;
