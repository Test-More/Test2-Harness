use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Scalar::Util ();

# Capture fallback dispatch + events. The watchdog body lives on
# Test2::Harness2::PreloadRouter now; it calls _ipcm_service_standalone
# and emit_service_event on the harness backref, so monkey-patches on
# Test2::Harness2 still cover both branches.
my @standalone;
my @events;
{
    no warnings 'redefine';
    *Test2::Harness2::_ipcm_service_standalone = sub {
        my (undef, %p) = @_;
        push @standalone, \%p;
        return 'started';
    };
    *Test2::Harness2::emit_service_event = sub {
        my (undef, %p) = @_;
        push @events, \%p;
    };
}

my $harness = bless {
    resource_services => {},
}, 'Test2::Harness2';

my $router = bless {
    harness                            => $harness,
    pending_preload_spawns             => {},
    preload_service_spawn_timeout_secs => 5,
}, 'Test2::Harness2::PreloadRouter';
Scalar::Util::weaken($router->{harness});
$harness->{preload_router} = $router;

# Recent pending: not timed out.
$router->{pending_preload_spawns}{1} = {
    entry        => {name => 'fresh', class => 'F', resource => bless({}, 'X')},
    peer_name    => 'resource-fresh',
    preload_name => 'preload-myapp',
    sent_at      => time,
};

# Stale pending: timed out.
$router->{pending_preload_spawns}{2} = {
    entry        => {name => 'stale', service_class => 'S', resource => bless({}, 'X'), service_args => [], scope => 'global'},
    peer_name    => 'resource-stale',
    preload_name => 'preload-myapp',
    sent_at      => time - 120,
};

$harness->_check_pending_preload_spawn_timeouts;

ok(exists $router->{pending_preload_spawns}{1}, 'fresh pending preserved');
ok(!exists $router->{pending_preload_spawns}{2}, 'stale pending dropped');

is(scalar @standalone, 1, 'one fallback spawn issued');
is($standalone[0]->{name}, 'stale', 'fallback used the stale entry');

is(scalar @events, 1, 'one timeout event emitted');
is($events[0]->{kind}, 'resource_spawn_preload_timeout', 'correct event kind');

done_testing;
