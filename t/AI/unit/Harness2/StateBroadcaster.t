use strict;
use warnings;

use Test2::V0;

use Test2::Harness2::StateBroadcaster;
use Test2::Harness2::RunStates;

# Slot accessors so the tests can poke / inspect the broadcaster's
# internal subscriber state directly.
use constant SUBSCRIBERS      => Test2::Harness2::StateBroadcaster::SUBSCRIBERS();
use constant SUBSCRIBER_RETRY => Test2::Harness2::StateBroadcaster::SUBSCRIBER_RETRY();

# --- fake collaborators ---------------------------------------------------
{
    package SBTRun;
    sub new      { my ($c, $id) = @_; bless { run_id => $id }, $c }
    sub run_id   { $_[0]->{run_id} }
}

{
    package SBTState;
    sub new      { my ($c, $id) = @_; bless { run_id => $id, state => 'running' }, $c }
    sub TO_JSON  { return { %{$_[0]} } }
}

{
    package SBTClient;
    sub new { bless { sent => [], fail_send => 0, fail_peer_alive => undef }, shift }
    sub send_message {
        my ($self, $peer, $payload) = @_;
        if ($self->{fail_send}) {
            die "boom\n";
        }
        push @{$self->{sent}}, [$peer, $payload];
        return 1;
    }
    sub peer_exists {
        my ($self, $peer) = @_;
        return $self->{fail_peer_alive}->{$peer} if exists $self->{fail_peer_alive}->{$peer};
        return 1;
    }
}

{
    package SBTScheduler;
    # Fake scheduler -- the broadcaster only needs the queue
    # introspection helpers (run_in_queue / run_by_id) plus a
    # finalize_run_if_complete hook to record the call so the test
    # can assert on it.
    sub new {
        my ($c, %p) = @_;
        return bless {
            queue     => $p{queue} // [],
            finalized => [],
        }, $c;
    }
    sub run_in_queue {
        my ($self, $rid) = @_;
        return 1 if grep { $_->run_id eq $rid } @{$self->{queue}};
        return 0;
    }
    sub run_by_id {
        my ($self, $rid) = @_;
        for my $r (@{$self->{queue}}) {
            return $r if $r->run_id eq $rid;
        }
        return undef;
    }
    sub finalize_run_if_complete {
        my ($self, $run) = @_;
        push @{$self->{finalized}}, $run->run_id;
    }
}

{
    package SBTHarness;
    # The broadcaster reaches the queue through the harness's
    # scheduler accessor; RUN_STATES and COMPLETED_RUNS flow through
    # the broadcaster's direct RunStates ref.
    sub new {
        my ($c, %p) = @_;
        my $self = bless {
            client    => $p{client},
            scheduler => SBTScheduler->new(queue => $p{queue} // []),
        }, $c;
        return $self;
    }
    sub client    { $_[0]->{client} }
    sub scheduler { $_[0]->{scheduler} }
    # finalize calls are recorded on the scheduler now; expose them
    # so the existing assertions still read `$h->{finalized}`.
    sub finalized { $_[0]->{scheduler}->{finalized} }
}

# Fake IPC message: ->from returns the peer name.
{
    package SBTMsg;
    sub new  { my ($c, $from) = @_; bless { from => $from }, $c }
    sub from { $_[0]->{from} }
}

# Load Test2::Harness2 just so the QUEUE constant the broadcaster
# references resolves to a defined slot-key string.
require Test2::Harness2;

# --- subscribe / unsubscribe round-trip -----------------------------------
subtest subscribe_unsubscribe_roundtrip => sub {
    my $client = SBTClient->new;
    my $rid    = 'r-1';
    my $run    = SBTRun->new($rid);
    my $rstate = SBTState->new($rid);

    my $rs = Test2::Harness2::RunStates->new(run_states => {$rid => $rstate});
    my $h  = SBTHarness->new(client => $client, queue => [$run]);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => $rs,
    );

    my $msg  = SBTMsg->new('peer-a');
    my $resp = $sb->subscribe({ state => 1, run => $rid }, $msg);
    is($resp, { ok => 1 }, 'subscribe succeeded');

    ok($sb->{+SUBSCRIBERS}{'peer-a'}, 'peer registered');
    is($sb->{+SUBSCRIBERS}{'peer-a'}{runs}{$rid}, 1, 'run subscription recorded');

    # Initial snapshot was dispatched on subscribe(state => 1).
    is(scalar @{$client->{sent}}, 1, 'initial snapshot sent');
    is($client->{sent}[0][0], 'peer-a', 'sent to peer-a');
    is($client->{sent}[0][1]{type},   'state', 'type=state');
    is($client->{sent}[0][1]{run_id}, $rid,    'run_id correct');
    is($client->{sent}[0][1]{state}{state}, 'running', 'live snapshot state passed through');

    # unsubscribe -> registry empty
    my $resp2 = $sb->unsubscribe({}, $msg);
    is($resp2, { ok => 1 }, 'unsubscribe succeeded');
    ok(!exists $sb->{+SUBSCRIBERS}{'peer-a'}, 'peer dropped');
};

subtest subscribe_rejects_unknown_run => sub {
    my $client = SBTClient->new;
    my $rs = Test2::Harness2::RunStates->new;
    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => $rs,
    );

    my $resp = $sb->subscribe(
        { state => 1, runs => ['nope'] },
        SBTMsg->new('peer-x'),
    );
    is($resp->{ok}, 0, 'rejected');
    like($resp->{error}, qr/unknown run 'nope'/, 'error names the run id');
    ok(!exists $sb->{+SUBSCRIBERS}{'peer-x'}, 'peer not registered');
};

subtest subscribe_requires_peer => sub {
    my $rs = Test2::Harness2::RunStates->new;
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => SBTHarness->new(client => SBTClient->new),
        run_states => $rs,
    );
    my $resp = $sb->subscribe({}, undef);
    is($resp->{ok}, 0, 'no msg -> rejected');
    like($resp->{error}, qr/IPC message context/, 'error explains why');
};

# --- snapshot reads RunStates ---------------------------------------------
subtest snapshot_uses_completed_runs => sub {
    my $client = SBTClient->new;
    my $rid    = 'done-1';

    my $rs = Test2::Harness2::RunStates->new;
    $rs->record_completed($rid, {
        results => { foo => 1 },
        done    => ['j1'],
        pass    => 1,
    });

    # Hold a strong ref to the harness so Role::Subsystem's weakened
    # backref does not clear out from under the test.
    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => $rs,
    );

    $sb->send_snapshot('peer-c', run_id => $rid);

    is(scalar @{$client->{sent}}, 1, 'one snapshot sent');
    my $payload = $client->{sent}[0][1];
    is($payload->{type},   'state', 'type=state');
    is($payload->{run_id}, $rid,    'run_id correct');
    is($payload->{state}{state}, 'complete', 'wrapped completed snapshot marks complete');
    is($payload->{state}{pass}, 1, 'pass forwarded');
    is($payload->{state}{results}, { foo => 1 }, 'results forwarded');
};

subtest snapshot_unknown_run_is_silent => sub {
    my $client = SBTClient->new;
    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );

    $sb->send_snapshot('peer-c', run_id => 'never-heard-of-it');
    is(scalar @{$client->{sent}}, 0, 'no message sent for unknown run');
};

# --- broadcast_run_state fans out + asks harness to finalize -------------
subtest broadcast_run_state_notifies_and_finalizes => sub {
    my $client = SBTClient->new;
    my $rid    = 'live-1';
    my $run    = SBTRun->new($rid);
    my $rstate = SBTState->new($rid);

    my $rs = Test2::Harness2::RunStates->new(run_states => {$rid => $rstate});
    my $h  = SBTHarness->new(client => $client, queue => [$run]);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => $rs,
    );

    # Pre-register a state-subscribed peer for this run.
    $sb->{+SUBSCRIBERS}{'peer-q'} = {
        global => 0,
        runs   => { $rid => 1 },
        state  => 1,
    };

    $sb->broadcast_run_state($rid);

    is(scalar @{$client->{sent}}, 1, 'fan-out happened');
    is($client->{sent}[0][0], 'peer-q', 'sent to subscribed peer');
    is($client->{sent}[0][1]{run_id}, $rid, 'with correct run_id');

    is(\@{$h->finalized}, [$rid], 'harness asked to finalize the matching run');
};

# --- retry queueing on send failure with cap behavior --------------------
subtest send_failure_queues_retry_and_caps => sub {
    my $client = SBTClient->new;
    $client->{fail_send} = 1;             # all sends throw
    $client->{fail_peer_alive} = { 'peer-z' => 1 }; # peer is reported alive

    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );

    # Pre-register so the failure path doesn't wipe an empty registry.
    $sb->{+SUBSCRIBERS}{'peer-z'} = { runs => {}, state => 1, global => 0 };

    # Cap is 1024; push 1025 payloads with unique ids so we can verify
    # FIFO trimming dropped the oldest one.
    my $cap = Test2::Harness2::StateBroadcaster::SUBSCRIBER_RETRY_CAP();
    my $warnings = 0;
    {
        local $SIG{__WARN__} = sub { $warnings++ };
        for my $i (0 .. $cap) {
            $sb->send('peer-z', { idx => $i });
        }
    }

    my $q = $sb->{+SUBSCRIBER_RETRY}{'peer-z'}{pending};
    is(scalar(@$q), $cap, "queue capped at $cap entries");
    is($q->[0]{idx}, 1, 'oldest entry (idx 0) was dropped (FIFO)');
    is($q->[-1]{idx}, $cap, 'newest entry retained');
    ok($warnings >= 1, 'at least one cap-exceeded warning fired');
};

subtest send_failure_peer_gone_unsubscribes => sub {
    my $client = SBTClient->new;
    $client->{fail_send}       = 1;
    $client->{fail_peer_alive} = { 'peer-gone' => 0 }; # peer reported dead

    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );
    $sb->{+SUBSCRIBERS}{'peer-gone'} = { runs => {}, state => 1, global => 0 };
    $sb->{+SUBSCRIBER_RETRY}{'peer-gone'} = { pending => [] };

    my $warnings = 0;
    {
        local $SIG{__WARN__} = sub { $warnings++ };
        $sb->send('peer-gone', { hi => 1 });
    }
    ok($warnings >= 1, 'warned about gone peer');
    ok(!exists $sb->{+SUBSCRIBERS}{'peer-gone'},      'peer removed from registry');
    ok(!exists $sb->{+SUBSCRIBER_RETRY}{'peer-gone'}, 'retry queue removed for peer');
};

# --- drain_retries: success path drops the entry --------------------------
subtest drain_retries_success_drops_queue => sub {
    my $client = SBTClient->new;
    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );

    $sb->{+SUBSCRIBER_RETRY}{'peer-d'} = {
        pending => [ { idx => 1 }, { idx => 2 } ],
    };

    $sb->drain_retries;

    is(scalar @{$client->{sent}}, 2, 'both retries flushed');
    ok(!exists $sb->{+SUBSCRIBER_RETRY}{'peer-d'}, 'queue dropped after success');
};

subtest drain_retries_keeps_queue_on_transient_failure => sub {
    my $client = SBTClient->new;
    $client->{fail_send}       = 1;
    $client->{fail_peer_alive} = { 'peer-t' => 1 };

    my $h  = SBTHarness->new(client => $client);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );
    $sb->{+SUBSCRIBERS}{'peer-t'} = { runs => {}, state => 1, global => 0 };
    $sb->{+SUBSCRIBER_RETRY}{'peer-t'} = {
        pending => [ { idx => 'a' }, { idx => 'b' }, { idx => 'c' } ],
    };

    $sb->drain_retries;

    my $q = $sb->{+SUBSCRIBER_RETRY}{'peer-t'}{pending};
    is(scalar @$q, 3, 'all three payloads retained on transient failure');
    is($q->[0]{idx}, 'a', 'order preserved (oldest first)');
};

# --- forget_peer cleans both registries -----------------------------------
subtest forget_peer_drops_subscriber_and_retry => sub {
    my $h  = SBTHarness->new(client => SBTClient->new);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );
    $sb->{+SUBSCRIBERS}{'peer-f'}      = { runs => {}, state => 1, global => 0 };
    $sb->{+SUBSCRIBER_RETRY}{'peer-f'} = { pending => [{ x => 1 }] };

    my $warnings = 0;
    {
        local $SIG{__WARN__} = sub { $warnings++ };
        $sb->forget_peer('peer-f');
    }
    ok($warnings >= 1, 'forget_peer warned (unexpected departure)');
    ok(!exists $sb->{+SUBSCRIBERS}{'peer-f'},      'subscribers cleaned');
    ok(!exists $sb->{+SUBSCRIBER_RETRY}{'peer-f'}, 'retry queue cleaned');
};

subtest forget_peer_unknown_is_silent => sub {
    my $h  = SBTHarness->new(client => SBTClient->new);
    my $sb = Test2::Harness2::StateBroadcaster->new(
        harness    => $h,
        run_states => Test2::Harness2::RunStates->new,
    );
    my $warnings = 0;
    {
        local $SIG{__WARN__} = sub { $warnings++ };
        $sb->forget_peer('never-subscribed');
    }
    is($warnings, 0, 'no warning for peer that was never subscribed');
};

done_testing;
