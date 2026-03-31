use Test2::V0 -target => 'App::Yath::Command::kill';

subtest 'run() calls client->kill()' => sub {
    my $called = 0;
    my $mock = mock 'App::Yath::Client' => (
        override => [
            new  => sub { bless {}, 'App::Yath::Client' },
            kill => sub { $called++; return },
        ],
    );

    my $obj = CLASS->new(settings => {});
    $obj->run();
    is($called, 1, 'run() invokes kill() on the client');
};

done_testing;
