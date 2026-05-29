use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector qw/collect/;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# The collector can decode the child's raw output by a named charset so
# non-ASCII output is not mangled. Without an encoding the bytes pass through
# untouched; with one, raw stream lines are Encode::decode'd before becoming
# event text.

sub stream_details ($dir) {
    my $r = open_zstd_reader("$dir/events.jsonl.zst");
    my @out;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        my $e = decode_json($line);
        push @out => $e->{facet_data}{from_stream}{details}
            if $e->{facet_data}{from_stream};
    }
    return \@out;
}

subtest decodes_utf8 => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Child prints the UTF-8 bytes of "é" (U+00E9) as raw bytes.
    collect(
        name     => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => "$dir/events.jsonl.zst"),
        encoding => 'UTF-8',
        exec     => [$^X, '-e', 'binmode(STDOUT); print "caf\xC3\xA9\n"'],
    );

    my $details = stream_details($dir);
    my ($line) = grep { defined && /caf/ } @$details;
    is($line, "caf\x{E9}", "utf-8 bytes decoded to the wide character");
};

subtest passthrough_without_encoding => sub {
    my $dir = tempdir(CLEANUP => 1);

    collect(
        name => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => "$dir/events.jsonl.zst"),
        exec => [$^X, '-e', 'print "plain ascii\n"'],
    );

    my $details = stream_details($dir);
    ok((grep { ($_ // '') eq 'plain ascii' } @$details), "ascii passes through unchanged with no encoding");
};

done_testing;
