use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Scalar::Util ();

# Stub a client that records what was sent.
{
    package FakeClient;
    sub new { bless { sent => [], die_on => undef }, 'FakeClient' }
    sub send_message {
        my ($self, $peer, $payload) = @_;
        die "send failed\n" if $self->{die_on};
        push @{$self->{sent}}, [$peer, $payload];
        return 1;
    }
}

# Stub a Resource::Preload look-alike: spawn_service_via_preload
# derives the IPC bus name via peer_name_for_preload($res), which
# calls $res->name and $res->scope. The bus name is 'preload-<n>' for
# global scope.
{
    package FakePreloadRes;
    sub new { bless { name => $_[1], scope => $_[2] // 'global' }, $_[0] }
    sub name  { $_[0]->{name} }
    sub scope { $_[0]->{scope} }
}

# Stub the harness + preload-router pair far enough to exercise
# spawn_service_via_preload. The router needs a harness backref so it
# can reach the client + name + pid.
sub make_harness {
    my $fake_client = FakeClient->new;
    my $harness = bless {
        name              => 'harness',
        resource_services => {},
        _PRELOAD_SPAWN_COUNTER => 0,
    }, 'Test2::Harness2';
    my $router = bless {
        harness                => $harness,
        pending_preload_spawns => {},
    }, 'Test2::Harness2::PreloadRouter';
    Scalar::Util::weaken($router->{harness});
    $harness->{preload_router} = $router;
    no warnings 'redefine';
    *Test2::Harness2::client = sub { $fake_client };
    return ($harness, $fake_client, $router);
}

# Happy path.
{
    my ($harness, $client, $router) = make_harness();
    my $entry = {
        name          => 'myres',
        scope         => 'global',
        service_class => 'My::Res::Class',
        service_args  => {x => 1},
        resource      => bless({}, 'X'),
    };
    my $preload_info = {
        pid      => $$,
        name     => 'myapp',                          # tracking name
        resource => FakePreloadRes->new('myapp'),     # supplies bus-name derivation
    };
    my $spawn_id = $router->spawn_service_via_preload($preload_info, $entry);

    ok($spawn_id, 'returns a spawn_id');
    my $pending = $router->{pending_preload_spawns};
    is(scalar(keys %$pending), 1, 'one pending entry installed');
    is($pending->{$spawn_id}{peer_name}, 'resource-myres', 'pending peer_name');
    is($pending->{$spawn_id}{preload_name}, 'preload-myapp', 'pending preload_name');

    is(scalar @{ $client->{sent} }, 1, 'one message sent');
    my ($peer, $payload) = @{ $client->{sent}->[0] };
    is($peer, 'preload-myapp', 'addressed preload by name');
    is($payload->{kind},      'spawn_service', 'kind set');
    is($payload->{class},     'My::Res::Class', 'class carried');
    is($payload->{peer_name}, 'resource-myres', 'peer_name carried');
    is($payload->{notify_to}, 'harness',        'notify_to is harness name');
    is($payload->{spawn_id},  $spawn_id,        'spawn_id correlation');
}

# Send failure: pending entry rolled back, undef returned.
{
    my ($harness, $client, $router) = make_harness();
    $client->{die_on} = 1;
    my $entry = {
        name          => 'broken',
        scope         => 'global',
        service_class => 'My::Res::Class',
        service_args  => {},
        resource      => bless({}, 'X'),
    };
    my $preload_info = {
        pid      => $$,
        name     => 'dead',
        resource => FakePreloadRes->new('dead'),
    };
    my @warns;
    local $SIG{__WARN__} = sub { push @warns, @_ };
    my $r = $router->spawn_service_via_preload($preload_info, $entry);

    is($r, undef, 'returns undef on send failure');
    is(scalar(keys %{ $router->{pending_preload_spawns} // {} }), 0,
       'pending entry rolled back');
    like(\@warns, [match qr/spawn dispatch.*failed/], 'warned about failure');
}

# ctor_args includes watch_pids => [harness_pid].
{
    my ($harness, $client, $router) = make_harness();
    no warnings 'redefine';
    local *Test2::Harness2::pid = sub { 4242 };
    my $entry = {
        name          => 'myres',
        scope         => 'global',
        service_class => 'My::Res::Class',
        service_args  => {x => 1},
        resource      => bless({}, 'X'),
    };
    my $preload_info = {
        pid      => $$,
        name     => 'myapp',
        resource => FakePreloadRes->new('myapp'),
    };
    $router->spawn_service_via_preload($preload_info, $entry);
    my (undef, $payload) = @{ $client->{sent}->[-1] };
    is($payload->{ctor_args}{watch_pids}, [4242],
       'ctor_args inserts harness pid into watch_pids');
    ok(!grep({ $_ == $preload_info->{pid} } @{$payload->{ctor_args}{watch_pids}}),
       'preload pid is NOT in watch_pids');
}

done_testing;
