use Test2::V0 -target => 'Test2::Harness::Client';

subtest 'constructor' => sub {
    my $client = $CLASS->new;
    ok($client->isa($CLASS), 'creates instance with no args');
};

subtest 'abstract methods die when not overridden' => sub {
    my $client = $CLASS->new;
    like(
        dies { $client->ipc },
        qr/ipc.*not implemented/i,
        'ipc() dies in base class',
    );
    like(
        dies { $client->connect },
        qr/connect.*not implemented/i,
        'connect() dies in base class',
    );
};

subtest 'send_and_get — success path returns response' => sub {
    my $client = $CLASS->new;

    my $fake_con = mock {} => (
        add => [
            send_and_get => sub {
                return {
                    api      => {success => 1},
                    response => 'pong',
                };
            },
        ],
    );

    {
        no warnings 'redefine';
        local *Test2::Harness::Client::connect = sub { $fake_con };
        my $result = $client->send_and_get('ping');
        is($result, 'pong', 'send_and_get returns response on success');
    }
};

subtest 'send_and_get — failure path croaks' => sub {
    my $client = $CLASS->new;

    my $fake_con = mock {} => (
        add => [
            send_and_get => sub {
                return {
                    api      => {success => 0, error => 'something failed'},
                    response => undef,
                };
            },
        ],
    );

    {
        no warnings 'redefine';
        local *Test2::Harness::Client::connect = sub { $fake_con };
        like(
            dies { $client->send_and_get('stop') },
            qr/API Call failed/,
            'send_and_get croaks on failure',
        );
    }
};

subtest 'ping delegates to send_and_get' => sub {
    my $client = $CLASS->new;
    my @calls;

    my $fake_con = mock {} => (
        add => [
            send_and_get => sub {
                push @calls, [@_];
                return {api => {success => 1}, response => 'pong'};
            },
        ],
    );

    {
        no warnings 'redefine';
        local *Test2::Harness::Client::connect = sub { $fake_con };
        my $res = $client->ping;
        is($res, 'pong', 'ping returns pong');
    }
};

done_testing;
