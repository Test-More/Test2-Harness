use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @events;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

# Run a real Test2::V0 script through the collector as a test job. is_test
# makes the collector set T2_FORMATTER=Stream2, so Test2::API installs our
# stream formatter and the assertions arrive as JSON event bursts.
my $dir = tempdir(CLEANUP => 1);
my $ef  = "$dir/events.jsonl.zst";

my $exit = Test2::Harness2::Collector->start(
    name         => "collector-test", is_test => 1, run_uuid => "RUN-1",
    recorder     => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
    exec_command => [$^X, '-Ilib', 't/AI/scripts/stream2_job.pl'],
);

is($exit, 0, "collector returned 0");

my @events = read_events($ef);
ok(@events, "captured events");

my @asserts = grep { $_->{facet_data}{assert} } @events;
my @details = map  { $_->{facet_data}{assert}{details} } @asserts;

ok(
    (grep { ($_ // '') eq 'pass one' } @details),
    "got the 'pass one' assertion via Stream2",
);
ok(
    (grep { ($_ // '') eq 'math works' } @details),
    "got the 'math works' assertion via Stream2",
);

ok((grep { $_->{facet_data}{plan} } @events), "got a plan facet");

# No UUIDs, no sync fields, no redundant/empty noise made it to disk.
ok(!(grep { ref $_ eq 'ARRAY' } @events),     "sync markers were not recorded");
ok(!(grep { exists $_->{event_id} } @events), "no event_id stamped on any event");

my ($a) = @asserts;
ok(!exists $a->{facet_data}{trace}{full_caller}, "trace.full_caller purged");
ok(!exists $a->{facet_data}{control},            "empty control facet purged");

my ($plan_e) = grep { $_->{facet_data}{plan} } @events;
ok(!exists $plan_e->{facet_data}{control}, "control facet (only a null terminate) purged");

my ($exit_e) = grep { $_->{facet_data}{harness_process_exit} } @events;
is($exit_e->{facet_data}{harness_process_exit}{all}, 0, "test job exited 0");

done_testing;
