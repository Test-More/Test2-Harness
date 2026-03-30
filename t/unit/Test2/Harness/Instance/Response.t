use Test2::V0 -target => 'Test2::Harness::Instance::Response';

subtest 'required attributes' => sub {
    like(
        dies { $CLASS->new(response => undef, api => {success => 1}) },
        qr/response_id.*required/i,
        'response_id is required',
    );
    like(
        dies { $CLASS->new(response_id => '1', api => {success => 1}) },
        qr/response.*required/i,
        'response is required (existence check)',
    );
    like(
        dies { $CLASS->new(response_id => '1', response => undef) },
        qr/api.*required/i,
        'api is required',
    );
};

subtest 'valid construction with undef response' => sub {
    # response existence is checked with exists, so undef is valid
    my $res = $CLASS->new(
        response_id => 'res-1',
        response    => undef,
        api         => {success => 1},
    );
    ok($res->isa($CLASS), 'creates instance with undef response');
    is($res->response_id, 'res-1', 'response_id accessor');
    ok(!defined($res->response), 'response can be undef');
    is($res->api, {success => 1}, 'api accessor');
};

subtest 'valid construction with data response' => sub {
    my $res = $CLASS->new(
        response_id => 'res-2',
        response    => {data => 'value'},
        api         => {success => 1},
    );
    is($res->response, {data => 'value'}, 'response accessor');
};

subtest 'success method' => sub {
    my $ok = $CLASS->new(
        response_id => 'res-3',
        response    => undef,
        api         => {success => 1},
    );
    is($ok->success, 1, 'success returns 1 for success');

    my $fail = $CLASS->new(
        response_id => 'res-4',
        response    => undef,
        api         => {success => 0, error => 'oops'},
    );
    is($fail->success, 0, 'success returns 0 for failure');
};

subtest 'inherits from Message' => sub {
    require Test2::Harness::Instance::Message;
    my $res = $CLASS->new(
        response_id => 'res-5',
        response    => undef,
        api         => {success => 1},
    );
    ok($res->isa('Test2::Harness::Instance::Message'), 'inherits from Message');
};

done_testing;
