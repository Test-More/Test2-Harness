use Test2::V0;

use Test2::Harness2::Util::IPC qw{
    ipc_default_protocol
    ipc_default_serializer
    ipc_default_spawn_args
    ipc_default_connect_args
    ipc_zstd_dict_path
};

subtest 'ipc_default_protocol returns ConnectionUnix class' => sub {
    is(
        ipc_default_protocol(),
        'IPC::Manager::Client::ConnectionUnix',
        'fully qualified ConnectionUnix class name',
    );
};

subtest 'ipc_default_serializer is JSON::Zstd at level 3' => sub {
    my $spec = ipc_default_serializer();
    is(ref $spec, 'ARRAY', 'arrayref form so IPC::Manager builds an instance');

    my ($class, %args) = @$spec;
    is($class,       'JSON::Zstd', 'JSON::Zstd serializer');
    is($args{level}, 3,            'level 3');

    if (defined $args{dictionary}) {
        ok(-f $args{dictionary}, "dictionary path is a real file ($args{dictionary})");
        ok(-r _,                 'dictionary is readable');
    }
    else {
        # Acceptable when running uninstalled without ShareDir staging.
        is(ipc_zstd_dict_path(), undef, 'no dictionary => helper agrees');
    }
};

subtest 'ipc_default_spawn_args bundles protocol and serializer' => sub {
    my %args = ipc_default_spawn_args();
    is($args{protocol}, ipc_default_protocol(), 'protocol matches helper');
    is(
        $args{serializer},
        ipc_default_serializer(),
        'serializer matches helper',
    );
};

subtest 'ipc_default_connect_args turns off listen for non-services' => sub {
    my %args = ipc_default_connect_args();
    is($args{listen}, 0, 'listen=0 (collectors and spawn handles do not accept inbound)');
};

subtest 'ipc_zstd_dict_path: undef when share file missing' => sub {
    # No way to force the share dir to be missing in-process, so just
    # assert the contract: either undef or a readable file path.
    my $p = ipc_zstd_dict_path();
    if (defined $p) {
        ok(-f $p && -r _, "share-supplied dictionary is readable ($p)");
    }
    else {
        pass('no installed share dict: helper returned undef');
    }
};

done_testing;
