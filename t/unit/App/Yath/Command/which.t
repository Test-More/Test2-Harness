use Test2::V0 -target => 'App::Yath::Command::which';

subtest 'run() when no daemon found' => sub {
    my $find_called = 0;
    my $mock = mock 'App::Yath::IPC' => (
        override => [
            new  => sub { bless {}, 'App::Yath::IPC' },
            find => sub { $find_called++; return () },
        ],
    );

    my $obj = CLASS->new(settings => {});
    open my $fh, '>', \(my $stdout = '');
    my $oldfh = select $fh;
    my $ret = $obj->run();
    select $oldfh;

    ok($find_called, 'find() was called on IPC');
    is($ret, 0, 'returns 0');
    like($stdout, qr/No persistent harness was found/, 'prints not-found message');
};

subtest 'run() when daemon found' => sub {
    my $mock = mock 'App::Yath::IPC' => (
        override => [
            new  => sub { bless {}, 'App::Yath::IPC' },
            find => sub { return {dir => '/tmp/yath', pid => 12345} },
        ],
    );

    my $obj = CLASS->new(settings => {});
    open my $fh, '>', \(my $stdout = '');
    my $oldfh = select $fh;
    my $ret = $obj->run();
    select $oldfh;

    is($ret, 0, 'returns 0');
    like($stdout, qr/Found a persistent runner/, 'prints found message');
};

done_testing;
