use Test2::V0;
use Test2::Harness2::Spawn;

# The peer-gone error shapes that IPC::Manager::Service::Handle::sync_request
# can throw when the service exits before its ACK is received.
my $PEER_GONE_AWAIT = "peer 'harness' went away while awaiting response";
my $PEER_GONE_RECIP = "'harness' is not a valid message recipient";
my $OTHER_ERROR     = "serialization error in request";
my $WKEY            = Test2::Harness2::Spawn::_WAITED();

# Build a minimal Spawn object for unit testing.
# terminate_on_destroy => 0 prevents DESTROY from calling terminate() on a
# fake PID when the object goes out of scope.
# _waited is pre-set to 1 so wait() short-circuits without a real child.
sub make_spawn {
    my $spawn = Test2::Harness2::Spawn->new(
        pid                  => $$,
        ipcm_info            => {},
        workdir              => '/tmp',
        name                 => 'harness',
        terminate_on_destroy => 0,
    );
    $spawn->{$WKEY} = 1;
    return $spawn;
}

subtest 'finish() returns cleanly on success' => sub {
    my $spawn = make_spawn();

    my @called;
    no warnings 'redefine';
    local *Test2::Harness2::Spawn::wait_until_idle = sub { 1 };
    local *Test2::Harness2::Spawn::_send_request = sub {
        push @called => $_[1];
        return {ok => 1};
    };

    my $ok = eval { $spawn->finish; 1 };
    ok($ok, 'finish() does not die on success');
    is($called[0], 'finish', '_send_request called with "finish"');
};

# -------------------------------------------------------------------------
# finish() — peer-gone "went away" shape
# -------------------------------------------------------------------------
subtest 'finish() absorbs peer-gone "went away" error' => sub {
    my $spawn = make_spawn();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::wait_until_idle = sub { 1 };
    local *Test2::Harness2::Spawn::_send_request = sub { die "$PEER_GONE_AWAIT\n" };

    my $ok = eval { $spawn->finish; 1 };
    ok($ok, 'finish() does not die on peer-gone "went away"');
};

# -------------------------------------------------------------------------
# finish() — peer-gone "not a valid recipient" shape
# -------------------------------------------------------------------------
subtest 'finish() absorbs peer-gone "not a valid recipient" error' => sub {
    my $spawn = make_spawn();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::wait_until_idle = sub { 1 };
    local *Test2::Harness2::Spawn::_send_request = sub { die "$PEER_GONE_RECIP\n" };

    my $ok = eval { $spawn->finish; 1 };
    ok($ok, 'finish() does not die on peer-gone "not a valid recipient"');
};

# -------------------------------------------------------------------------
# finish() — non-peer-gone error must propagate
# -------------------------------------------------------------------------
subtest 'finish() propagates non-peer-gone errors' => sub {
    my $spawn = make_spawn();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::wait_until_idle = sub { 1 };
    local *Test2::Harness2::Spawn::_send_request = sub { die "$OTHER_ERROR\n" };

    my $ok  = eval { $spawn->finish; 1 };
    my $err = $@;
    ok(!$ok, 'finish() dies on non-peer-gone error');
    like($err, qr/\Q$OTHER_ERROR\E/, 'correct error propagated');
};

# -------------------------------------------------------------------------
# terminate() — success path: wait() is called
# -------------------------------------------------------------------------
subtest 'terminate() returns cleanly on success' => sub {
    my $spawn = make_spawn();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::_send_request = sub { return {ok => 1} };

    my $ok = eval { $spawn->terminate; 1 };
    ok($ok, 'terminate() does not die on success');
};

# -------------------------------------------------------------------------
# terminate() — peer-gone shape: absorbs error and still calls wait()
# -------------------------------------------------------------------------
subtest 'terminate() absorbs peer-gone error and still calls wait()' => sub {
    my $spawn = make_spawn();
    my $wkey  = Test2::Harness2::Spawn::_WAITED();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::_send_request = sub { die "$PEER_GONE_AWAIT\n" };

    my $ok = eval { $spawn->terminate; 1 };
    ok($ok, 'terminate() does not die on peer-gone error');
    is($spawn->{$wkey}, 1, 'wait() was reached (guard still 1 — idempotent)');
};

# -------------------------------------------------------------------------
# terminate() — non-peer-gone error must propagate (after wait())
# -------------------------------------------------------------------------
subtest 'terminate() propagates non-peer-gone errors (after wait())' => sub {
    my $spawn = make_spawn();
    my $wkey  = Test2::Harness2::Spawn::_WAITED();

    no warnings 'redefine';
    local *Test2::Harness2::Spawn::_send_request = sub { die "$OTHER_ERROR\n" };

    my $ok  = eval { $spawn->terminate; 1 };
    my $err = $@;
    ok(!$ok, 'terminate() dies on non-peer-gone error');
    like($err, qr/\Q$OTHER_ERROR\E/, 'correct error propagated');
    is($spawn->{$wkey}, 1, 'wait() was still called before die (guard 1)');
};

done_testing;
