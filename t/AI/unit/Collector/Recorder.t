use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use POSIX ();
use Atomic::Pipe;

use Test2::Harness2::Event;
use Test2::Harness2::Util::Zstd qw/compress_blob open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

use Test2::Harness2::Collector::Recorder;

# The base recorder is the pipeline sink: it writes every event handed to it
# to a single jsonl.zst events file, and on finalize it closes that file and
# sends a finalization message to any notification pipes it was given.

my $tmp = tempdir(CLEANUP => 1);

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @out;
    while (defined(my $line = $r->readline)) {
        chomp $line;
        next unless length $line;
        push @out => decode_json($line);
    }
    return \@out;
}

subtest does_role => sub {
    ok(
        Test2::Harness2::Collector::Recorder->DOES('Test2::Harness2::Collector::Role::Recorder'),
        "base recorder consumes the Recorder role",
    );
};

subtest events_file_required => sub {
    my $err = dies { Test2::Harness2::Collector::Recorder->new };
    like($err, qr/events_file/, "constructing without events_file croaks");
};

subtest records_events => sub {
    my $file = "$tmp/events.jsonl.zst";
    my $rec  = Test2::Harness2::Collector::Recorder->new(events_file => $file);

    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'A', details => 'one'}]}));
    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'B', details => 'two'}]}));
    $rec->finalize;

    my $events = read_events($file);
    is(scalar(@$events), 2, "wrote both events");
    is($events->[0]{facet_data}{info}[0]{details}, 'one', "first event payload preserved");
    is($events->[1]{facet_data}{info}[0]{details}, 'two', "second event payload preserved");
};

subtest compressed_form_fast_path => sub {
    my $file = "$tmp/compressed.jsonl.zst";
    my $rec  = Test2::Harness2::Collector::Recorder->new(events_file => $file);

    my $event = Test2::Harness2::Event->new(facet_data => {info => [{tag => 'C', details => 'verbatim'}]});
    $event->{compressed_form} = compress_blob($event->as_json . "\n");

    $rec->record_event($event);
    $rec->finalize;

    my $events = read_events($file);
    is(scalar(@$events), 1, "wrote the verbatim event");
    is($events->[0]{facet_data}{info}[0]{details}, 'verbatim', "verbatim frame decodes back");
};

subtest finalize_notifies_live_pipes => sub {
    my ($r, $w) = Atomic::Pipe->pair(compression => 'zstd', keep_compressed => 1);

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file => "$tmp/notify-events.jsonl.zst",
        pipes       => [$w],
    );
    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'D'}]}));
    $rec->finalize;

    $r->blocking(0);
    my $msg = $r->read_message;
    ok(defined $msg, "a message arrived on the pipe");
    my $decoded = decode_json($msg);
    ok($decoded->{facet_data}{harness_collector_finalized}, "finalization message sent on finalize");
};

subtest finalize_notifies_fifo_pipe => sub {
    my $path = "$tmp/notify.fifo";
    POSIX::mkfifo($path, 0700) or skip_all("mkfifo unavailable: $!");

    # Reader opens first so the recorder's write-FIFO open does not block.
    my $r = Atomic::Pipe->read_fifo($path, compression => 'zstd', keep_compressed => 1);

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file => "$tmp/fifo-events.jsonl.zst",
        pipes       => [{fifo => $path}],
    );
    $rec->finalize;

    $r->blocking(0);
    my $msg     = $r->read_message;
    my $decoded = decode_json($msg);
    ok($decoded->{facet_data}{harness_collector_finalized}, "finalization message sent over a fifo spec");
};

subtest finalize_is_idempotent => sub {
    my $file = "$tmp/idem.jsonl.zst";
    my $rec  = Test2::Harness2::Collector::Recorder->new(events_file => $file);
    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'E'}]}));
    $rec->finalize;
    ok(lives { $rec->finalize }, "second finalize is a no-op");
};

done_testing;
