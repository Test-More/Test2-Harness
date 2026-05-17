use Test2::V0;
use Test2::Harness2::PreloadRouter;

# Peer-name derivation lives on the preload router subsystem and is a
# class method (does not need a constructed router instance).

# Global scope: just the service name.
is(
    Test2::Harness2::PreloadRouter->peer_name_for_resource({name => 'myres', scope => 'global'}),
    'resource-myres',
    'global-scope peer name',
);

# Run scope: includes run_id segment.
is(
    Test2::Harness2::PreloadRouter->peer_name_for_resource({name => 'myres', scope => 'run', run => 7}),
    'resource-7-myres',
    'run-scope peer name',
);

# Run scope without run_id: falls back to global form (defensive).
is(
    Test2::Harness2::PreloadRouter->peer_name_for_resource({name => 'myres', scope => 'run'}),
    'resource-myres',
    'run-scope without run defaults to global form',
);

done_testing;
