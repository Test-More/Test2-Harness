use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Scalar::Util ();

# Stubs. spawn_service_via_preload + _ipcm_service_standalone are
# what the drain helpers dispatch to; we capture the dispatches so we
# can assert which path the queue took without involving a real fork.
# All the moved logic now lives on Test2::Harness2::PreloadRouter, so
# the redefines target that class.
my (@spawned, @standalone);
{
    no warnings 'redefine';
    *Test2::Harness2::PreloadRouter::spawn_service_via_preload = sub {
        my (undef, $pinfo, $entry) = @_;
        push @spawned, [$pinfo->{name}, $entry->{name}];
        return 99;
    };
    *Test2::Harness2::_ipcm_service_standalone = sub {
        my (undef, %p) = @_;
        push @standalone, $p{name};
        return 'started';
    };
    *Test2::Harness2::PreloadRouter::find_eligible = sub {
        my ($self, $pname) = @_;
        return $self->{eligible}{$pname};
    };
    *Test2::Harness2::emit_service_event = sub { };
}

sub make_pair {
    my %router_extra = @_;
    my $h = bless {
        resources => [],
    }, 'Test2::Harness2';
    my $router = bless {
        harness                    => $h,
        eligible                   => {},
        resources_awaiting_preload => {},
        known_preload_names        => {},
        run_states                 => {},
        %router_extra,
    }, 'Test2::Harness2::PreloadRouter';
    Scalar::Util::weaken($router->{harness});
    $h->{preload_router} = $router;
    return ($h, $router);
}

# Drain on preload_ready: a queued dependent fires through
# spawn_service_via_preload as soon as the matching preload is
# eligible + ready.
{
    @spawned    = ();
    @standalone = ();
    my ($h, $router) = make_pair(known_preload_names => {myapp => 1});

    push @{$router->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    is(scalar @spawned,    0, 'no spawn yet');
    is(scalar @standalone, 0, 'no standalone yet');

    # Preload becomes eligible + ready event arrives.
    $router->{eligible}{myapp} = {name => 'preload-myapp', pid => $$};
    $h->_handle_preload_state_message('preload_ready', {preload_name => 'myapp'});

    is(scalar @spawned, 1, 'queue drained');
    is($spawned[0], ['preload-myapp', 'pool'], 'dispatched the queued entry');
    is(scalar @{$router->{resources_awaiting_preload}{myapp} // []}, 0,
        'queue emptied');
}

# Permanent broken: flush queue through _ipcm_service_standalone so the
# dependent still gets a service, just unpreloaded.
{
    @spawned    = ();
    @standalone = ();
    my ($h, $router) = make_pair(known_preload_names => {myapp => 1});

    push @{$router->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    $h->_handle_preload_state_message('preload_broken',
        {preload_name => 'myapp', permanent => 1, error => 'load failed'});

    is(scalar @spawned,    0, 'no preload spawn');
    is(scalar @standalone, 1, 'dispatched standalone');
    is($standalone[0], 'pool', 'standalone got the queued entry');
}

# Transient broken (not permanent): queue stays intact so a later
# preload_ready can still drain it.
{
    @spawned    = ();
    @standalone = ();
    my ($h, $router) = make_pair(known_preload_names => {myapp => 1});

    push @{$router->{resources_awaiting_preload}{myapp}} => {
        name          => 'pool',
        scope         => 'global',
        service_class => 'X',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/p',
    };

    $h->_handle_preload_state_message('preload_broken',
        {preload_name => 'myapp', permanent => 0, error => 'transient'});

    is(scalar @spawned,    0, 'no preload spawn');
    is(scalar @standalone, 0, 'no standalone yet (transient broken keeps queue)');
    is(scalar @{$router->{resources_awaiting_preload}{myapp} // []}, 1,
        'queue preserved on transient broken');
}

done_testing;
