use Test2::V0 -target => 'App::Yath::Command::abort';

subtest 'run() calls client->abort()' => sub {
    my $called = 0;
    my $mock = mock 'App::Yath::Client' => (
        override => [
            new   => sub { bless {}, 'App::Yath::Client' },
            abort => sub { $called++; return },
        ],
    );

    my $obj = CLASS->new(settings => {});
    $obj->run();
    is($called, 1, 'run() invokes abort() on the client');
};

done_testing;
