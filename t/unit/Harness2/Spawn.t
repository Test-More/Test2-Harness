use Test2::V0;
use Test2::Harness2::Spawn;

subtest 'construction' => sub {
    my $s = Test2::Harness2::Spawn->new(
        pid       => 12345,
        ipcm_info => {protocol => 'X'},
        workdir   => '/tmp/x',
        name      => 'harness',
    );
    is($s->pid,                  12345,    'pid');
    is($s->workdir,              '/tmp/x', 'workdir');
    is($s->terminate_on_destroy, 1,        'default on');
};

subtest 'detach turns off terminate_on_destroy' => sub {
    my $s = Test2::Harness2::Spawn->new(
        pid       => 12345,
        ipcm_info => {},
        workdir   => '/tmp/x',
        name      => 'h',
    );

    # Fake the IPC call by overriding the send method.
    my @sent;
    no warnings 'redefine';
    local *Test2::Harness2::Spawn::_send_request = sub {
        my ($self, $name, $payload) = @_;
        push @sent => [$name, $payload];
        return {ok => 1};
    };

    $s->detach;

    is($sent[0][0],              'detach', 'sent detach request');
    is($sent[0][1]{pid},         $$,       'payload includes caller pid');
    is($s->terminate_on_destroy, 0,        'flag cleared');
};

done_testing;
