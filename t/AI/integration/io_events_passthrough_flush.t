use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

# With io_events on, a top-level print is passed through the tie to its dup of
# the real handle. That dup must be unbuffered, or output is lost when the test
# exits hard (POSIX::_exit) before Perl flushes -- which is exactly what
# xt/all_subtests.t does, dropping its "1..4" plan line.

my $dir = tempdir(CLEANUP => 1);
my $ef  = "$dir/events.jsonl.zst";

Test2::Harness2::Collector->start(
    name         => "flush", is_test => 1, run_uuid => "RUN",
    processor    => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
    recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
    exec_command => [$^X, '-Ilib', 't/AI/scripts/passthrough_exit_job.pl'],
);

my $r = open_zstd_reader($ef);
my $seen = 0;
while (defined(my $line = $r->readline)) {
    next unless length $line;
    $seen = 1 if $line =~ /PASSTHROUGH-MARKER/;
}

ok($seen, "passthrough output survives a hard exit (the real-handle dup is unbuffered)");

done_testing;
