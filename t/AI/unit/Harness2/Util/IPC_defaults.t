use Test2::V0;

use Test2::Harness2::Util::IPC qw{
    ipc_default_protocol
    ipc_default_serializer
    ipc_default_spawn_args
    ipc_default_connect_args
    atomic_pipe_compression_args
    apply_atomic_pipe_compression
};

use Atomic::Pipe;

subtest 'ipc_default_protocol returns ConnectionUnix class' => sub {
    is(
        ipc_default_protocol(),
        'IPC::Manager::Client::ConnectionUnix',
        'fully qualified ConnectionUnix class name',
    );
};

subtest 'ipc_default_serializer is the JSON::Zstd class string' => sub {
    is(
        ipc_default_serializer(),
        'JSON::Zstd',
        'plain class name; IPC::Manager uses it without per-instance bless',
    );
};

subtest 'ipc_default_spawn_args bundles protocol and serializer' => sub {
    my %args = ipc_default_spawn_args();
    is($args{protocol},   ipc_default_protocol(),   'protocol matches helper');
    is($args{serializer}, ipc_default_serializer(), 'serializer matches helper');
};

subtest 'ipc_default_connect_args turns off listen for non-services' => sub {
    my %args = ipc_default_connect_args();
    is($args{listen}, 0, 'listen=0 (collectors and spawn handles do not accept inbound)');
};

subtest 'atomic_pipe_compression_args: zstd, no level, no dict' => sub {
    my %args = atomic_pipe_compression_args();
    is($args{compression},     'zstd', 'compression algo');
    is($args{keep_compressed}, 1,      'keep_compressed exposes on-wire frame');
    ok(!exists $args{compression_level},          'no explicit level (library default applies)');
    ok(!exists $args{compression_dictionary_file}, 'no dictionary plumbed');
};

subtest 'pair() with compression args round-trips a message' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());
    is($w->compression, 'zstd', 'writer end has compression on');
    is($r->compression, 'zstd', 'reader end has compression on');

    $w->write_message('{"hello":"world"}');
    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message',           'reader saw a framed message');
    is($data, '{"hello":"world"}', 'payload decoded back to plaintext');
};

subtest 'apply_atomic_pipe_compression: enables zstd post-construct' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    is($w->compression, undef, 'pair starts uncompressed');

    apply_atomic_pipe_compression($w);
    apply_atomic_pipe_compression($r);

    is($w->compression, 'zstd', 'writer enabled after apply');

    $w->write_message('{"k":"v"}');
    my ($type, $data) = $r->get_line_burst_or_data();
    is($type, 'message',   'message frame emerged after enabling compression');
    is($data, '{"k":"v"}', 'roundtrip decode matches');
};

done_testing;
