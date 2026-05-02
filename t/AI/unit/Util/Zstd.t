use strict;
use warnings;

use Test2::V0;
use File::Temp qw/tempdir/;

use Test2::Harness2::Util::Zstd qw{
    compress_blob
    decompress_blob
    compress_file_atomic
    decompress_file
    open_zstd_writer
    open_zstd_reader
};

my $tmp = tempdir(CLEANUP => 1);

# ----------------------------------------------------------------------
# One-shot blob round-trips.

subtest 'compress_blob / decompress_blob' => sub {
    my $payload = qq[{"hello":"world","line":1}\n] x 50;
    my $frame   = compress_blob($payload);
    ok(length($frame) < length($payload), "frame is smaller than source");
    is(decompress_blob($frame), $payload, "round-trip restores payload");
};

# ----------------------------------------------------------------------
# Atomic file write / read.

subtest 'compress_file_atomic / decompress_file' => sub {
    my $path    = "$tmp/snapshot.json.zst";
    my $payload = qq[{"snapshot":true,"big":"@{['x' x 5000]}"}];
    compress_file_atomic($path, $payload);
    ok(-f $path, "file exists after atomic write");
    is(decompress_file($path), $payload, "round-trip");

    # Compressed size should be much smaller than payload.
    ok(-s $path < length($payload) / 2, "compressed file is at least 2x smaller");
};

# ----------------------------------------------------------------------
# Append-safe writer + multi-frame reader.

subtest 'writer/reader round-trip' => sub {
    my $path = "$tmp/events.jsonl.zst";

    my @lines = map { qq[{"event_id":$_,"kind":"sample"}\n] } 1 .. 100;

    my $w = open_zstd_writer($path);
    $w->print($_) for @lines;
    $w->close;

    my $r = open_zstd_reader($path);
    my @got;
    while (defined(my $line = $r->readline)) {
        push @got, $line;
    }
    is(\@got, \@lines, "all lines round-tripped through writer + reader");
};

# ----------------------------------------------------------------------
# Tail-style reading: writer keeps appending while reader keeps reading.

subtest 'writer + reader interleaved' => sub {
    my $path = "$tmp/tail.jsonl.zst";

    my $w = open_zstd_writer($path);
    $w->print(qq[{"i":1}\n]);
    $w->print(qq[{"i":2}\n]);

    my $r = open_zstd_reader($path);
    is($r->readline, qq[{"i":1}\n], "first frame visible to reader");
    is($r->readline, qq[{"i":2}\n], "second frame visible to reader");

    $w->print(qq[{"i":3}\n]);
    is($r->readline, qq[{"i":3}\n], "appended frame visible after refill");

    $w->close;
};

done_testing;
