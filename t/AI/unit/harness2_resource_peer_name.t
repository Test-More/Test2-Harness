use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;

# Peer-name derivation lives on the preload router subsystem; the
# harness exposes a compatibility shim that delegates. Test both
# the package-function form (used internally by SpawnGateway when
# it does not have a router yet) and the harness-level shim.
my $harness = bless {}, 'Test2::Harness2';

# Global scope: just the service name.
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'global'}),
    'resource-myres',
    'global-scope peer name',
);

# Run scope: includes run_id segment.
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'run', run => 7}),
    'resource-7-myres',
    'run-scope peer name',
);

# Run scope without run_id: falls back to global form (defensive).
is(
    $harness->_resource_peer_name({name => 'myres', scope => 'run'}),
    'resource-myres',
    'run-scope without run defaults to global form',
);

# Same checks via the router's package-method form.
is(
    Test2::Harness2::PreloadRouter->peer_name_for_resource({name => 'myres', scope => 'global'}),
    'resource-myres',
    'PreloadRouter->peer_name_for_resource (global)',
);

is(
    Test2::Harness2::PreloadRouter->peer_name_for_resource({name => 'myres', scope => 'run', run => 7}),
    'resource-7-myres',
    'PreloadRouter->peer_name_for_resource (run with run_id)',
);

done_testing;
