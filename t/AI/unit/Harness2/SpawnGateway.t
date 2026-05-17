use Test2::V0;
use POSIX ();
use Time::HiRes ();
use Test2::Harness2::SpawnGateway;

# --- fake collaborators ---------------------------------------------------
{
    package SGTClient;
    sub new { my ($c) = @_; bless { sent => [] }, $c }
    sub send_message {
        my ($self, $peer, $payload) = @_;
        push @{$self->{sent}}, [ $peer, $payload ];
        return 1;
    }
}

{
    package SGTPreloadResource;
    sub new {
        my ($c, %p) = @_;
        bless { name => $p{name} // 'BASE', scope => $p{scope} // 'global' }, $c;
    }
    sub name                { $_[0]->{name}  }
    sub scope               { $_[0]->{scope} }
    sub is_permanent_broken { 0 }
}

# Fake harness: implements only the bits SpawnGateway calls -- name,
# client, ipcm_info, _find_eligible_preload_service. The latter is the
# interim cross-domain call SpawnGateway makes through the harness
# until extraction 8 (PreloadRouter) replaces it.
{
    package SGTHarness;
    sub new { my ($c, %p) = @_; bless { %p }, $c }
    sub name      { $_[0]->{name}      // 'harness' }
    sub client    { $_[0]->{client} }
    sub ipcm_info { $_[0]->{ipcm_info} // 'IPC::Manager::Client::ConnectionUnix(/tmp/x)' }
    sub _find_eligible_preload_service {
        my ($self, $stage) = @_;
        return $self->{preloads}->{$stage};
    }
}

# --- handle_request -------------------------------------------------------
subtest 'handle_request: happy path' => sub {
    my $client = SGTClient->new;
    my $res    = SGTPreloadResource->new(name => 'BASE');
    my $h = SGTHarness->new(
        client   => $client,
        preloads => { BASE => { pid => 4242, resource => $res } },
    );
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);

    my $resp = $sg->handle_request({
        script_abs => '/tmp/foo.pl',
        argv       => ['a', 'b'],
        env        => { HOME => '/h' },
        cwd        => '/tmp',
        sock_path  => '/tmp/spawn-1.sock',
        notify_to  => 'yath-spawn-1',
        stage      => 'BASE',
    });

    is($resp->{ok},   1,         'ok=1');
    is($resp->{mode}, 'preload', 'mode=preload');
    ok($resp->{spawn_id}, 'spawn_id allocated');

    is(scalar(@{$client->{sent}}), 1, 'one send_message');
    is($client->{sent}[0][0], 'preload-BASE', 'sent to preload bus name');
    is($client->{sent}[0][1]{kind}, 'spawn_script', 'kind=spawn_script');
    is($client->{sent}[0][1]{script_abs}, '/tmp/foo.pl', 'script_abs forwarded');
    is($client->{sent}[0][1]{notify_to}, 'harness', 'notify_to is harness');

    ok($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{$resp->{spawn_id}},
        'pending entry installed');
};

subtest 'handle_request: missing required field' => sub {
    my $h  = SGTHarness->new(client => SGTClient->new, preloads => {});
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    my $resp = $sg->handle_request({
        # no script_abs
        env => {}, cwd => '/tmp', sock_path => '/tmp/x.sock',
        notify_to => 'x', stage => 'BASE',
    });
    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/script_abs/, 'error mentions missing field');
};

subtest 'handle_request: missing stage' => sub {
    my $h  = SGTHarness->new(client => SGTClient->new, preloads => {});
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    my $resp = $sg->handle_request({
        script_abs => '/tmp/foo.pl',
        env => {}, cwd => '/tmp', sock_path => '/tmp/x.sock',
        notify_to => 'x',
    });
    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/stage/, 'error mentions stage');
};

subtest 'handle_request: no eligible preload' => sub {
    my $h  = SGTHarness->new(client => SGTClient->new, preloads => {});
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    my $resp = $sg->handle_request({
        script_abs => '/tmp/foo.pl',
        env => {}, cwd => '/tmp', sock_path => '/tmp/x.sock',
        notify_to => 'x',
        stage     => 'NOPE',
    });
    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/NOPE/, 'error mentions requested stage');
};

subtest 'handle_request: transport assert fails' => sub {
    my $h = SGTHarness->new(
        client    => SGTClient->new,
        preloads  => {},
        ipcm_info => 'IPC::Manager::Client::JSONFile(/tmp/x.json)',
    );
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    my $resp = $sg->handle_request({
        script_abs => '/tmp/foo.pl',
        env => {}, cwd => '/tmp', sock_path => '/tmp/x.sock',
        notify_to => 'x', stage => 'BASE',
    });
    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/ConnectionUnix/, 'error mentions required transport');
};

# --- handle_spawned + handle_pid_exit normal path ------------------------
subtest 'handle_spawned then handle_pid_exit normal path' => sub {
    my $client = SGTClient->new;
    my $h  = SGTHarness->new(client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);

    $sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        11 => { notify_to => 'cli-z', stage => 'BASE', preload_pid => 999 },
    };

    # script_spawned arrives first -> child_pid recorded.
    $sg->handle_spawned({ kind => 'script_spawned', spawn_id => 11, pid => 77777 });
    is($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{11}{child_pid},
        77777, 'child pid recorded');

    # Now the reap fires -- handle_pid_exit must dispatch + return true.
    my $rc = $sg->handle_pid_exit(77777, (12 << 8));
    is($rc, 1, 'handle_pid_exit returned true (definitive match)');
    is(scalar(@{$client->{sent}}), 1, 'one script_exited dispatched');
    is($client->{sent}[0][0], 'cli-z', 'sent to notify_to');
    is($client->{sent}[0][1]{kind}, 'script_exited', 'kind=script_exited');
    is($client->{sent}[0][1]{exit}, 12, 'exit code forwarded');
    is($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{11}, undef,
        'pending entry cleared');
};

# --- handle_pid_exit race case --------------------------------------------
subtest 'handle_pid_exit race case: stashes + returns false' => sub {
    my $client = SGTClient->new;
    my $h  = SGTHarness->new(client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);

    # Pending entry has no child_pid yet (script_spawned not seen yet).
    $sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        12 => { notify_to => 'cli-w', stage => 'BASE', preload_pid => 999 },
    };

    my $rc = $sg->handle_pid_exit(88888, (3 << 8));
    is($rc, 0, 'handle_pid_exit returned false (race case)');
    is($sg->{Test2::Harness2::SpawnGateway::_SCRIPT_SPAWN_EXITS()}{88888},
        (3 << 8), 'raw exit stashed under pid');
    is(scalar(@{$client->{sent}}), 0, 'no script_exited dispatched yet');

    # Now the late script_spawned arrives -- handle_spawned should drain
    # the stash and emit script_exited.
    $sg->handle_spawned({ kind => 'script_spawned', spawn_id => 12, pid => 88888 });
    is(scalar(@{$client->{sent}}), 1, 'script_exited dispatched after stash drain');
    is($client->{sent}[0][1]{exit}, 3, 'exit code forwarded from stash');
    is($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{12}, undef,
        'pending entry cleared');
    is($sg->{Test2::Harness2::SpawnGateway::_SCRIPT_SPAWN_EXITS()}{88888}, undef,
        'stashed exit drained');
};

subtest 'handle_pid_exit: nothing pending, no stash, returns false' => sub {
    my $client = SGTClient->new;
    my $h  = SGTHarness->new(client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);
    # empty table -> not expecting unmatched -> no stash, return false
    my $rc = $sg->handle_pid_exit(99999, (1 << 8));
    is($rc, 0, 'returned false');
    is($sg->{Test2::Harness2::SpawnGateway::_SCRIPT_SPAWN_EXITS()}{99999}, undef,
        'no speculative stash when no pending entry lacks a child_pid');
};

# --- poll dispatches stashed (real-reaped) exits --------------------------
subtest 'poll dispatches exits for entries with known child pids' => sub {
    my $client = SGTClient->new;
    my $h  = SGTHarness->new(client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);

    my $kid = fork // die "fork: $!";
    if (!$kid) { POSIX::_exit(7) }
    Time::HiRes::sleep(0.1);

    $sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        13 => { notify_to => 'cli-p', child_pid => $kid },
    };

    $sg->poll;

    is(scalar(@{$client->{sent}}), 1, 'one notification sent');
    is($client->{sent}[0][0], 'cli-p', 'sent to notify_to');
    is($client->{sent}[0][1]{exit}, 7, 'exit forwarded');
    is($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{13}, undef,
        'pending entry cleared');
};

subtest 'poll leaves still-running entries alone' => sub {
    my $client = SGTClient->new;
    my $h  = SGTHarness->new(client => $client);
    my $sg = Test2::Harness2::SpawnGateway->new(harness => $h);

    $sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()} = {
        14 => { notify_to => 'cli-r', child_pid => $$ },  # our own pid is alive
    };

    $sg->poll;
    ok($sg->{Test2::Harness2::SpawnGateway::PENDING_SCRIPT_SPAWNS()}{14},
        'still pending');
};

done_testing;
