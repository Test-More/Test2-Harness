use Test2::V0;
use POSIX ();

use Test2::Harness2::Role::Service;

# Minimal consumer that satisfies the role's requires and records every
# hook call / event emit so the tests can assert on them. Hash-backed
# because the role reaches into $self->{state}, $self->{kill_timeout},
# etc. via HashBase conventions.
{

    package T::Svc::Fake;
    use Object::HashBase qw{
        <workdir
        <name
        <kill_timeout
        <ipcm_info
        state
        own_pgroup
        watch_pids
        +events
        +calls
        +pids_to_return
    };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub init {
        my $self = shift;
        $self->{+KILL_TIMEOUT}   //= 1;
        $self->{+WORKDIR}        //= '/tmp';
        $self->{+NAME}           //= 'fake';
        $self->{+EVENTS}         //= [];
        $self->{+CALLS}          //= [];
        $self->{+PIDS_TO_RETURN} //= {};
    }

    sub emit_service_event {
        my ($self, %fields) = @_;
        push @{$self->{+EVENTS}} => \%fields;
        return;
    }

    sub hard_stop_pids {
        my $self = shift;
        push @{$self->{+CALLS}} => 'hard_stop_pids';
        return %{$self->{+PIDS_TO_RETURN}};
    }

    sub service_on_start {
        push @{$_[0]->{+CALLS}} => 'on_start';
        return;
    }

    sub service_started_fields {
        return (extra => 'flavor');
    }

    sub service_pre_hard_stop {
        push @{$_[0]->{+CALLS}} => 'pre_hard_stop';
        return;
    }

    sub service_post_hard_stop {
        push @{$_[0]->{+CALLS}} => 'post_hard_stop';
        return;
    }

    sub service_on_reaped {
        my ($self, $pid) = @_;
        push @{$self->{+CALLS}} => "on_reaped:$pid";
        return;
    }

    # The role's run_on_start eagerly calls $self->client to register
    # on the IPC bus. With no real ipcm_info plumbed in, the default
    # implementation tries to read stats files off disk and warns
    # "Failed to initialise IPC client in run_on_start: malformed JSON
    # ...". Stub it out so unit tests don't depend on a live bus.
    sub client { return undef }
}

subtest 'IPC::Manager::Role::Service contract defaults' => sub {
    my $svc = T::Svc::Fake->new;
    is($svc->orig_io, {}, 'orig_io returns empty hashref');
    is($svc->pid,     $$, 'pid defaults to $$');
    $svc->set_pid(42);
    is($svc->pid,        42,    'set_pid stores on the hash');
    is($svc->watch_pids, undef, 'watch_pids starts undef');
};

subtest 'handle_request routes to request_handler_* methods' => sub {
    my $svc = T::Svc::Fake->new;

    no warnings 'once', 'redefine';
    local *T::Svc::Fake::request_handler_ping = sub {
        my ($self, $payload) = @_;
        return {ok => 1, echo => $payload->{value}};
    };

    # Payload as a hashref (what Spawn->_send_request produces).
    my $res = $svc->handle_request({request => {request => 'ping', value => 7}});
    is($res, {ok => 1, echo => 7}, 'dispatched with payload');

    # Payload as a bareword (scalar).
    my $res2 = $svc->handle_request({request => 'ping'});
    is($res2, {ok => 1, echo => undef}, 'bareword payload dispatches');

    # Missing request type.
    my $res3 = $svc->handle_request({request => {}});
    like($res3->{error}, qr/missing request type/);

    # Unknown type.
    my $res4 = $svc->handle_request({request => {request => 'nope'}});
    like($res4->{error}, qr/unknown request 'nope'/);
};

subtest 'request_handler_terminate default calls perform_hard_stop' => sub {
    my $svc = T::Svc::Fake->new(pids_to_return => {});

    my $res = $svc->request_handler_terminate;
    is($res,          {ok => 1},     'returns ok');
    is($svc->{state}, 'terminating', 'state flipped to terminating');
    is(
        $svc->{+T::Svc::Fake::CALLS()}, [
            'pre_hard_stop',
            'hard_stop_pids',
            'post_hard_stop',
        ],
        'hooks fired in order (no pids to reap, so no on_reaped)'
    );
};

subtest 'run_on_start: pgroup + service_started emit + service_on_start' => sub {
    my $svc = T::Svc::Fake->new;

    $svc->run_on_start;

    is(scalar @{$svc->{+T::Svc::Fake::EVENTS()}}, 1, 'one event emitted');
    my $e = $svc->{+T::Svc::Fake::EVENTS()}->[0];
    is($e->{kind},    'service_started', 'kind is service_started');
    is($e->{pid},     $$,                'pid stamped');
    is($e->{name},    'fake',            'name from consumer');
    is($e->{workdir}, '/tmp',            'workdir from consumer');
    is($e->{extra},   'flavor',          'extra field from service_started_fields');

    is($svc->{+T::Svc::Fake::CALLS()}, ['on_start'], 'service_on_start fired');
    ok($svc->own_pgroup, 'own_pgroup set after successful setpgid');
    is($e->{pgroup_set},    1, 'pgroup_set flag in service_started event');
    is($e->{subreaper_set}, 0, 'subreaper_set flag in service_started event (become_sub_reaper default is 0)');
};

subtest 'perform_hard_stop runs the escalator and reap hooks' => sub {
    skip_all "fork required" unless $^O ne 'MSWin32' && eval { require Config; $Config::Config{d_fork} };

    my $pid = fork // die "fork: $!";
    if (!$pid) {
        # Child: handler that exits on TERM immediately so the parent
        # reaps inside the escalator loop.
        $SIG{TERM} = sub { POSIX::_exit(0) };
        my $done = 0;
        $SIG{ALRM} = sub { $done = 1 };
        POSIX::alarm(5);    # safety: don't outlive the test
        until ($done) { CORE::sleep 1 }
        POSIX::_exit(99);
    }

    my $svc = T::Svc::Fake->new(
        kill_timeout   => 1,
        pids_to_return => {$pid => {}},
    );

    $svc->perform_hard_stop;

    is($svc->{state}, 'terminating', 'state flipped');
    like(
        join(',', @{$svc->{+T::Svc::Fake::CALLS()}}),
        qr/pre_hard_stop,hard_stop_pids,on_reaped:\Q$pid\E,post_hard_stop/,
        'hooks fired in order including on_reaped',
    );
};

done_testing;
