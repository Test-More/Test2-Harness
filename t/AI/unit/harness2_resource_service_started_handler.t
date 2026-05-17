use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::PreloadRouter;
use Scalar::Util ();

my @tracked;
{
    no warnings 'redefine';
    *Test2::Harness2::track_resource_service = sub {
        my (undef, %p) = @_;
        push @tracked, \%p;
    };
}

my @events;
{
    no warnings 'redefine';
    *Test2::Harness2::emit_service_event = sub {
        my (undef, %p) = @_;
        push @events, \%p;
    };
}

{
    package FakeMsg;
    sub new { bless { content => $_[1] }, 'FakeMsg' }
    sub content { $_[0]->{content} }
}

sub make_harness {
    my (%pending) = @_;
    my $h = bless {
        resource_services => {},
        run_states        => {},
    }, 'Test2::Harness2';
    my $router = bless {
        harness                => $h,
        pending_preload_spawns => \%pending,
    }, 'Test2::Harness2::PreloadRouter';
    Scalar::Util::weaken($router->{harness});
    $h->{preload_router} = $router;
    return $h;
}

# Pending entry exists -> notification triggers track + event.
{
    @tracked = ();
    @events  = ();
    my $entry = {
        name          => 'opt-in-svc',
        scope         => 'global',
        service_class => 'My::Res::Class',
        service_args  => {},
        resource      => bless({}, 'X'),
        log_path      => '/tmp/x',
    };
    {
        package X;
        sub resource_name { 'opt-in' }
    }
    my $h = make_harness(
        42 => {
            entry        => $entry,
            peer_name    => 'resource-opt-in-svc',
            preload_pid  => $$,
            preload_name => 'preload-myapp',
            sent_at      => time,
        },
    );

    my $msg = FakeMsg->new({
        kind        => 'resource_service_started',
        via_preload => 1,
        spawn_id    => 42,
        pid         => 12345,
        peer_name   => 'resource-opt-in-svc',
    });
    $h->run_on_general_message($msg);

    is(scalar @tracked, 1, 'track_resource_service invoked once');
    is($tracked[0]->{pid},           12345,                 'pid recorded');
    is($tracked[0]->{name},          'resource-opt-in-svc', 'peer_name carried');
    is($tracked[0]->{service_class}, 'My::Res::Class',      'class carried');
    is($tracked[0]->{scope},         'global',              'scope carried');
    ok($tracked[0]->{via_preload},                          'via_preload flag set');

    is(scalar(keys %{ $h->preload_router->{pending_preload_spawns} }), 0,
       'pending entry cleared');

    is(scalar @events, 1, 'one event emitted');
    is($events[0]->{kind}, 'resource_spawn_via_preload', 'correct event kind');
}

# Unknown spawn_id -> silently dropped.
{
    @tracked = ();
    @events  = ();
    my $h = make_harness();    # no pending entries
    my $msg = FakeMsg->new({
        kind        => 'resource_service_started',
        via_preload => 1,
        spawn_id    => 99,
        pid         => 11111,
    });
    $h->run_on_general_message($msg);

    is(scalar @tracked, 0, 'no track call for unknown spawn_id');
    is(scalar @events,  0, 'no event for unknown spawn_id');
}

done_testing;
