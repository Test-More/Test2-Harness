use Test2::V0;

use Compress::Zstd ();
use File::Temp qw/tempdir/;

use Test2::Harness2::Event;
use Test2::Harness2::Collector::Logger::JSONL;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;

# Sanity: Event class exposes the new compressed_form slot, holds
# arbitrary bytes verbatim, drops it from the JSON encoding, and
# clear_compressed_form wipes both it and the as_json cache.

subtest 'Event compressed_form: round-trip' => sub {
    my $bytes = "\x00\x01\x02fake-frame";
    my $e     = Test2::Harness2::Event->new(
        event_id        => 'abc',
        facet_data      => {harness => {kind => 'demo'}},
        compressed_form => $bytes,
    );
    is($e->compressed_form, $bytes, 'accessor returns the stored bytes');

    my $json = $e->as_json;
    unlike(
        $json,
        qr/\Qfake-frame\E/,
        'JSON encoding does not leak compressed_form bytes',
    );
    unlike($json, qr/compressed_form/, 'no compressed_form key in JSON');

    # The cached JSON pairs with the cached frame; clearing the frame
    # invalidates the JSON cache so a subsequent mutation gets a
    # fresh encoding.
    $e->clear_compressed_form;
    is($e->compressed_form, undef, 'compressed_form cleared');
    is($e->{json},          undef, 'as_json cache invalidated');
    ok($e->as_json, 'as_json regenerates');
};

# JSONL logger fast-path: if the event has compressed_form bytes the
# logger appends them to the .zst file verbatim instead of running
# the payload through Compress::Zstd a second time. The file must
# still decode back to the same JSON the event would have produced.

subtest 'JSONL logger writes cached compressed frame verbatim' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/events.jsonl.zst";

    my $logger = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info   => 'unused',
        output_file => $path,
    );
    $logger->startup;

    my $payload = qq[{"event_id":"abc","stamp":1.5,"facet_data":{"harness":{"event_id":"abc"}}}];
    my $frame   = Compress::Zstd::compress($payload, 3);

    my $event = Test2::Harness2::Event->new(
        event_id        => 'abc',
        stamp           => 1.5,
        facet_data      => {harness => {event_id => 'abc'}},
        compressed_form => $frame,
    );

    $logger->log_event($event);
    $logger->shutdown;

    # Reading back the file decompresses to the same payload.
    # Producers may or may not include a trailing newline inside
    # the compressed payload; the JSON parser ignores leading and
    # trailing whitespace either way, so the test strips it before
    # comparing the bytes.
    my $reader = open_zstd_reader($path);
    my $line   = $reader->readline;
    s/\A\s+|\s+\z//g for $line;
    is(
        $line,
        '{"event_id":"abc","stamp":1.5,"facet_data":{"harness":{"event_id":"abc"}}}',
        'cached compressed frame round-trips through the file',
    );

    # The on-disk file should be byte-identical to the cached frame
    # (no extra recompression or wrapping).
    open(my $fh, '<', $path) or die "open $path: $!";
    binmode $fh;
    local $/;
    my $disk = <$fh>;
    close $fh;
    is($disk, $frame, 'on-disk bytes equal the cached compressed frame');
};

# Without compressed_form, the logger falls back to compressing the
# event's JSON itself. The output must still decode round-trip.

subtest 'JSONL logger compresses normally without compressed_form' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/events.jsonl.zst";

    my $logger = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info   => 'unused',
        output_file => $path,
    );
    $logger->startup;

    my $event = Test2::Harness2::Event->new(
        event_id   => 'def',
        stamp      => 2.5,
        facet_data => {harness => {event_id => 'def'}},
    );

    $logger->log_event($event);
    $logger->shutdown;

    my $reader = open_zstd_reader($path);
    my $line   = $reader->readline;
    like($line, qr/"event_id":"def"/, 'fallback path still writes a decodable frame');
};

done_testing;
