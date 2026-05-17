use Test2::V0;
use Test2::Harness2;
use Test2::Harness2::SpawnGateway;

my @sent;
my $client_mock = bless { sent => \@sent }, 'PSDClient';
sub PSDClient::send_message {
    my ($self, $peer, $payload) = @_;
    push @{$self->{sent}}, [ $peer, $payload ];
    return 1;
}

my $resource_mock = bless {
    name  => 'BASE',
    scope => 'global',
}, 'PSDPreloadResource';
sub PSDPreloadResource::name              { $_[0]->{name}  }
sub PSDPreloadResource::scope             { $_[0]->{scope} }
sub PSDPreloadResource::is_permanent_broken { 0 }

my $info_mock = {
    pid           => $$,
    resource      => $resource_mock,
    service_class => 'Test2::Harness2::PreloadService',
    scope         => 'global',
};

# Harness shell: bypass init, set the slots the SpawnGateway reaches
# through (resource_services + name + client + ipcm_info). Then
# construct a SpawnGateway and hang it off the harness so the
# request-handler shim's delegation works.
my $h = bless {
    Test2::Harness2::RESOURCE_SERVICES() => { $$ => $info_mock },
    Test2::Harness2::NAME()              => 'harness',
    ipcm_info                            => 'IPC::Manager::Client::ConnectionUnix(/tmp/x)',
    _CLIENT_MOCK                         => $client_mock,
}, 'Test2::Harness2';

no warnings 'redefine';
local *Test2::Harness2::client = sub { $_[0]->{_CLIENT_MOCK} };

$h->{Test2::Harness2::SPAWN_GATEWAY()} =
    Test2::Harness2::SpawnGateway->new(harness => $h);

subtest 'happy stage resolve' => sub {
    @sent = ();
    my $resp = $h->request_handler_spawn_script({
        request    => 'spawn_script',
        stage      => 'BASE',
        script_abs => '/tmp/foo.pl',
        argv       => ['a', 'b'],
        env        => { HOME => '/h' },
        cwd        => '/tmp',
        sock_path  => '/tmp/spawn-1.sock',
        notify_to  => 'yath-spawn-1234',
    });

    is($resp->{ok},    1,         'ok=1');
    is($resp->{mode},  'preload', 'mode=preload');
    ok($resp->{spawn_id}, 'spawn_id allocated');

    is(scalar(@sent), 1, 'one send_message');
    is($sent[0][0], 'preload-BASE', 'sent to preload bus name');
    is($sent[0][1]{kind}, 'spawn_script', 'kind=spawn_script');
    is($sent[0][1]{script_abs}, '/tmp/foo.pl', 'script_abs forwarded');
    is($sent[0][1]{sock_path},  '/tmp/spawn-1.sock', 'sock_path forwarded');
};

subtest 'missing stage -> ok=0' => sub {
    @sent = ();
    my $resp = $h->request_handler_spawn_script({
        request    => 'spawn_script',
        stage      => 'DOES_NOT_EXIST',
        script_abs => '/tmp/foo.pl',
        env        => {}, cwd => '/tmp',
        sock_path  => '/tmp/x.sock',
        notify_to  => 'x',
    });

    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/DOES_NOT_EXIST/, 'error mentions stage');
    is(scalar(@sent), 0, 'no message sent');
};

subtest 'non-ConnectionUnix transport -> ok=0' => sub {
    @sent = ();
    no warnings 'redefine';
    local *Test2::Harness2::SpawnGateway::assert_fdpass_transport = sub {
        die "yath spawn requires the ConnectionUnix IPC transport (got JSONFile)\n";
    };
    my $resp = $h->request_handler_spawn_script({
        request    => 'spawn_script',
        stage      => 'BASE',
        script_abs => '/tmp/foo.pl',
        env        => {}, cwd => '/tmp',
        sock_path  => '/tmp/x.sock',
        notify_to  => 'x',
    });

    is($resp->{ok}, 0, 'ok=0');
    like($resp->{error}, qr/ConnectionUnix/, 'error mentions required transport');
    is(scalar(@sent), 0, 'no message sent');
};

done_testing;
