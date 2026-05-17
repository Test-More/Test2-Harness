use Test2::V0;

# Build a minimal consumer of ResourceServiceHost that captures dispatch decisions.
{
    package FakeHost;
    use Test2::Harness2::Role::ResourceServiceHost;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::ResourceServiceHost';
    sub new { bless { %{$_[1] // {}}, calls => [] }, 'FakeHost' }
    sub name { 'fake-harness' }
    sub workdir { '/tmp' }
    sub service_host_scope { 'global' }
    sub service_host_run { undef }
    sub service_host_logdir { '/tmp' }
    sub client { $_[0]->{client} //= bless {sent => []}, 'FakeClient' }
    sub ipcm_info { 'fake-info' }
    sub pid_index { $_[0]->{pid_index} //= bless { resource_services => {} }, 'FakePidIndex' }
    sub emit_service_event { }
    sub preload_router {
        my $self = shift;
        $self->{preload_router} //= FakeRouter->new(host => $self);
        return $self->{preload_router};
    }
    sub _ipcm_service_standalone {
        my ($self, %p) = @_;
        push @{$self->{calls}}, ['standalone', $p{name}];
        return 'started';
    }
}
{
    package FakeRouter;
    sub new { my ($c, %p) = @_; bless { %p }, $c }
    sub find_eligible {
        my ($self, $pname) = @_;
        return $self->{host}->{eligible}{$pname};
    }
    sub spawn_service_via_preload {
        my ($self, $pinfo, $entry) = @_;
        push @{$self->{host}->{calls}}, ['preload', $pinfo->{name}, $entry->{name}];
        return 42;
    }
}
{
    package FakeClient;
    sub send_message { my ($s, $p, $payload) = @_; push @{$s->{sent}}, [$p, $payload]; }
}
{
    package FakePidIndex;
    sub resource_services          { $_[0]->{resource_services} }
    sub resource_service_tracked   { }
    sub resource_service_forgotten { }
}
{
    package My::Res::OptIn;
    sub preferred_preload { 'myapp' }
    sub resource_name { 'opt-in' }
    sub restartable { 1 }
}
{
    package My::Res::NoOptIn;
    sub preferred_preload { undef }
    sub resource_name { 'no-opt-in' }
    sub restartable { 1 }
}

# Resource opted in + matching preload eligible -> preload dispatch.
{
    my $host = FakeHost->new({
        eligible => {myapp => {name => 'preload-myapp', pid => $$}},
    });
    my $res = bless {}, 'My::Res::OptIn';
    $host->_start_service_entry(
        resource => $res,
        class    => 'My::Res::OptIn',
        name     => 'opt-in-svc',
        log_path => '/tmp/x',
        scope    => 'global',
        args     => [],
    );
    is($host->{calls}, [['preload', 'preload-myapp', 'opt-in-svc']],
       'dispatched via preload');
}

# Resource opted in but no matching preload -> standalone.
{
    my $host = FakeHost->new({eligible => {}});
    my $res = bless {}, 'My::Res::OptIn';
    $host->_start_service_entry(
        resource => $res,
        class    => 'My::Res::OptIn',
        name     => 'opt-in-svc',
        log_path => '/tmp/x',
        scope    => 'global',
        args     => [],
    );
    is($host->{calls}, [['standalone', 'opt-in-svc']], 'fell back to standalone');
}

# Resource did NOT opt in -> standalone regardless.
{
    my $host = FakeHost->new({
        eligible => {myapp => {name => 'preload-myapp', pid => $$}},
    });
    my $res = bless {}, 'My::Res::NoOptIn';
    $host->_start_service_entry(
        resource => $res,
        class    => 'My::Res::NoOptIn',
        name     => 'no-opt-in-svc',
        log_path => '/tmp/x',
        scope    => 'global',
        args     => [],
    );
    is($host->{calls}, [['standalone', 'no-opt-in-svc']],
       'no preferred_preload means no preload check');
}

done_testing;
