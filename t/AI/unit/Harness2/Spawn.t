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

subtest '_waited is declared in Object::HashBase' => sub {
    ok(Test2::Harness2::Spawn->can('_WAITED'), '_WAITED constant exists');

    my $s = Test2::Harness2::Spawn->new(
        pid       => 12345,
        ipcm_info => {},
        workdir   => '/tmp/x',
        name      => 'h',
    );
    my $key = Test2::Harness2::Spawn::_WAITED();
    is($s->{$key}, 0, '_waited initialised to 0');
};

subtest 'wait is idempotent via _waited guard' => sub {
    my $s = Test2::Harness2::Spawn->new(
        pid       => 12345,
        ipcm_info => {},
        workdir   => '/tmp/x',
        name      => 'h',
    );

    # Pre-set the guard so wait() short-circuits before hitting waitpid.
    # The purpose is to confirm the guard key the method reads is the same slot
    # Object::HashBase declares (i.e. _WAITED, not a raw '_waited' string).
    my $key = Test2::Harness2::Spawn::_WAITED();
    $s->{$key} = 1;
    $s->wait;    # must not die or call waitpid on a non-existent PID

    ok(1, 'wait() returns without error when _waited is set');
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
