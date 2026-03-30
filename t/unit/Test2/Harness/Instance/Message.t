use Test2::V0 -target => 'Test2::Harness::Instance::Message';

subtest 'constructor and basic attributes' => sub {
    my $msg = $CLASS->new(
        ipc_meta     => {seq => 1},
        connection   => 'con1',
        terminate    => 1,
        run_complete => 1,
    );
    ok($msg->isa($CLASS), 'creates instance');
    is($msg->ipc_meta,     {seq => 1}, 'ipc_meta accessor');
    is($msg->connection,   'con1',     'connection accessor');
    is($msg->terminate,    1,          'terminate accessor');
    is($msg->run_complete, 1,          'run_complete accessor');
};

subtest 'empty constructor' => sub {
    my $msg = $CLASS->new;
    ok($msg->isa($CLASS), 'constructs with no args');
};

subtest 'TO_JSON includes class field' => sub {
    my $msg = $CLASS->new(
        ipc_meta  => {seq => 99},
        terminate => 1,
    );
    my $json = $msg->TO_JSON;
    ref_ok($json, 'HASH', 'TO_JSON returns hashref');
    is($json->{class},     $CLASS,    'TO_JSON includes class key');
    is($json->{terminate}, 1,         'TO_JSON includes terminate');
};

done_testing;
