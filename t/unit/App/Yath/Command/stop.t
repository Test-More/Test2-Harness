use Test2::V0 -target => 'App::Yath::Command::stop';

subtest 'run() calls client->stop() and returns 0' => sub {
    my $called = 0;
    my $mock = mock 'App::Yath::Client' => (
        override => [
            new  => sub { bless {}, 'App::Yath::Client' },
            stop => sub { $called++; return },
        ],
    );

    my $obj = CLASS->new(settings => {});
    my $ret = $obj->run();
    is($called, 1, 'run() invokes stop() on the client');
    is($ret,    0, 'run() returns 0');
};

done_testing;
