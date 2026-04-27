use Test2::V0;
use File::Temp qw/tempdir/;
use File::Path qw/make_path/;
use Test2::Harness2::Util::JSON qw/write_json_file_atomic/;

use App::Yath2::LogArchive;
use App::Yath2::LogArchive::Format qw/default_writer_format/;
use App::Yath2::Streamer::Static;
use Test2::Harness2::Util::Zstd qw/open_zstd_writer open_zstd_reader/;

# When Streamer::Static extracts artifacts from a .yath archive into a
# private tempdir, it must also materialize the bundled zstd dictionary
# at the root of that tempdir. Logger::JSONL::log_reader walks parent
# directories of the file being read looking for "zstd-dict.bin"; if
# the dict is missing the reader falls back to dictless decode and
# croaks "zstd decompress failed" on every dict-compressed frame.
#
# Regression test for the CI failures on speedtag.t / times.t / failed.t
# where extracted .jsonl.zst payloads were dict-compressed but the
# extracted tmpdir had no dict.

my $tmp  = tempdir(CLEANUP => 1);
my $logs = "$tmp/logs";
make_path("$logs/services");

# Synthesise a small dict file. Any bytes work for round-trip;
# we just need writer and reader to agree on the same dict.
my $dict_path = "$logs/zstd-dict.bin";
{
    open(my $dfh, '>', $dict_path) or die "open $dict_path: $!";
    binmode $dfh;
    print {$dfh} "\xEC\x30\xA4\x37" . ("AB" x 4000);
    close $dfh;
}

# Write a dict-compressed JSONL.zst frame so the round trip exercises
# the dict-discovery path (not the dictless fallback).
my $writer = open_zstd_writer("$logs/services/harness.jsonl.zst", dict_path => $dict_path);
$writer->print('{"event_id":"X1","facet_data":{"harness":{}}}');
$writer->close;

# Minimal artifacts manifest so LogArchive treats services/harness.jsonl.zst
# as a real artifact even though no per-run state is needed for this test.
write_json_file_atomic("$logs/artifacts.json", {
    "services/harness.jsonl.zst" => 'Test2::Harness2::Collector::Logger::JSONL',
});

my $archive_path = "$tmp/run.yath";
App::Yath2::LogArchive->create(
    source => $logs,
    path   => $archive_path,
    format => default_writer_format(),
);
ok(-f $archive_path, 'archive written');

my $streamer = App::Yath2::Streamer::Static->new(
    log    => $archive_path,
    global => 1,
);

# Trigger archive extraction by resolving a non-dict artifact. This
# is the path that previously failed: extracting services/harness.jsonl.zst
# into a tmpdir without an accompanying zstd-dict.bin.
my $resolved = $streamer->_resolve_path('services/harness.jsonl.zst');
ok(defined $resolved && -f $resolved, 'jsonl.zst extracted')
    or diag "resolved=", ($resolved // '<undef>');

my $tmpdir = $streamer->{archive_tmpdir};
ok(defined $tmpdir && -d $tmpdir, 'archive tmpdir created');

my $tmp_dict = "$tmpdir/zstd-dict.bin";
ok(-f $tmp_dict, 'zstd-dict.bin materialized at archive tmpdir root');

# Bytes must match the original dict so any reader walking up from
# the extracted file finds an equivalent dict.
my $orig = do { local (@ARGV, $/) = $dict_path; <> };
my $copy = do { local (@ARGV, $/) = $tmp_dict;  <> };
is($copy, $orig, 'extracted dict bytes match the source dict');

# End-to-end: the reader's parent walk must find the materialized
# dict and successfully decode the dict-compressed frame.
my $reader = open_zstd_reader($resolved, dict_path => $tmp_dict);
my $line = $reader->readline;
like($line, qr/"event_id":"X1"/, 'dict-compressed frame round-trips through extraction');

done_testing;
