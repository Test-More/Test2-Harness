use Test2::V0 -target => 'App::Yath::Command::reload';
use App::Yath::Client;

subtest 'run() calls client->reload() and returns 0' => sub {
    my $called = 0;
    my $mock = mock 'App::Yath::Client' => (
        override => [
            new    => sub { bless {}, 'App::Yath::Client' },
            reload => sub { $called++; return },
        ],
    );

    my $obj = CLASS->new(settings => {});
    my $ret;
    open my $fh, '>', \(my $stdout = '');
    my $oldfh = select $fh;
    $ret = $obj->run();
    select $oldfh;

    is($called, 1, 'run() invokes reload() on the client');
    is($ret,    0, 'run() returns 0');
    like($stdout, qr/reload/i, 'prints reload status messages');
};

done_testing;
