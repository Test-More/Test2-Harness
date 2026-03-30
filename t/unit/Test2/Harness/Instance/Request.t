use Test2::V0 -target => 'Test2::Harness::Instance::Request';

subtest 'required attributes' => sub {
    like(
        dies { $CLASS->new(api_call => 'ping') },
        qr/request_id.*required/i,
        'request_id is required',
    );
    like(
        dies { $CLASS->new(request_id => '123') },
        qr/api_call.*required/i,
        'api_call is required',
    );
};

subtest 'valid construction' => sub {
    my $req = $CLASS->new(request_id => 'req-1', api_call => 'ping');
    ok($req->isa($CLASS), 'creates instance');
    is($req->request_id, 'req-1', 'request_id accessor');
    is($req->api_call,   'ping',  'api_call accessor');
};

subtest 'optional attributes' => sub {
    my $req = $CLASS->new(
        request_id    => 'req-2',
        api_call      => 'stop',
        args          => [1, 2, 3],
        do_not_respond => 1,
    );
    is($req->args,           [1, 2, 3], 'args accessor');
    is($req->do_not_respond, 1,         'do_not_respond accessor');
};

subtest 'inherits from Message' => sub {
    require Test2::Harness::Instance::Message;
    my $req = $CLASS->new(request_id => 'req-3', api_call => 'ping');
    ok($req->isa('Test2::Harness::Instance::Message'), 'inherits from Message');
};

subtest 'TO_JSON includes class' => sub {
    my $req  = $CLASS->new(request_id => 'req-4', api_call => 'ping');
    my $json = $req->TO_JSON;
    is($json->{class}, $CLASS, 'TO_JSON sets class to Request package');
};

done_testing;
