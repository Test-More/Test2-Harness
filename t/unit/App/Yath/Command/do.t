use Test2::V0 -target => 'App::Yath::Command::do';

subtest 'run() dies (stub command)' => sub {
    like(
        dies { CLASS->run() },
        qr/This should not be reachable/,
        'run() dies with expected message',
    );
};

done_testing;
