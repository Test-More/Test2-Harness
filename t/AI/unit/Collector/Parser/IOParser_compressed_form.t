use Test2::V0;

use Atomic::Pipe;

use Test2::Harness2::Collector::Parser::IOParser;
use Test2::Harness2::Util::IPC qw/atomic_pipe_compression_args/;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

# Verify the keep_compressed read path on Atomic::Pipe surfaces the
# on-wire frame, the IOParser accepts a `compressed` named param, and
# the resulting Event carries the bytes verbatim. This matches the
# collector's _read_handle / _ingest_item / _flush_buffer plumbing.

subtest 'Atomic::Pipe in keep_compressed mode emits compressed bytes' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1, atomic_pipe_compression_args());

    # No trailing newline -- frames self-delimit on the wire.
    my $payload = encode_json({event_id => 'roundtrip', stamp => 0.5});
    $w->write_message($payload);

    my @res = $r->get_line_burst_or_data();
    my ($type, $data, %extra) = @res;

    is($type, 'message', 'message type from compressed burst');
    is($data, $payload,  'decompressed payload matches');
    ok(defined $extra{compressed}, 'compressed bytes are surfaced')
        or diag("got tuple: " . join(', ', map { defined $_ ? $_ : 'undef' } @res));
    isnt($extra{compressed}, $data, 'compressed bytes differ from plaintext');

    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(
        ipcm_info => 'unused',
    );

    my $event = $parser->parse_io(
        stream     => 'stdout',
        event      => decode_json($data),
        stamp      => 1.0,
        compressed => $extra{compressed},
    );

    is(
        $event->compressed_form, $extra{compressed},
        'parser stores compressed bytes on the event'
    );
};

# A burst with no compressed entry (e.g. came from a non-keep_compressed
# pipe) must not leave a stray compressed_form on the event.

subtest 'parse_io without compressed leaves event clean' => sub {
    my $parser = Test2::Harness2::Collector::Parser::IOParser->new(
        ipcm_info => 'unused',
    );

    my $event = $parser->parse_io(
        stream => 'stdout',
        event  => {event_id => 'no-frame'},
        stamp  => 1.0,
    );

    is(
        $event->compressed_form, undef,
        'compressed_form stays undef when not supplied'
    );
};

done_testing;
