use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use IO::Select;

use Test2::Harness2::Event;
use Test2::Harness2::Util::Zstd qw/compress_blob open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util::Zstd::FrameBuffer;

use Test2::Harness2::Collector::Recorder;

# The base recorder is the pipeline sink: it writes every event handed to it
# to a single jsonl.zst events file, and on finalize it closes that file and
# sends a finalization message to any transition sockets it was given.

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

# Accept one connection on $listen, run $code (which triggers recorder writes),
# and return the decoded {type,payload} envelopes the recorder wrote to it.
sub drain_socket ($listen, $code) {
    my $conn = $listen->accept;    # recorder connected at construction
    $code->();
    $conn->blocking(0);

    my $fb  = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $sel = IO::Select->new($conn);
    while ($sel->can_read(2)) {
        my $buf = '';
        my $n = sysread($conn, $buf, 65536);
        last unless $n;
        $fb->push_bytes($buf);
    }
    return [map { decode_json($_->{payload}) } $fb->drain];
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
    is(scalar(@$events),                           2,     "wrote both events");
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
    is(scalar(@$events),                           1,          "wrote the verbatim event");
    is($events->[0]{facet_data}{info}[0]{details}, 'verbatim', "verbatim frame decodes back");
};

subtest finalize_notifies_socket => sub {
    my $path   = "$tmp/notify.sock";
    my $listen = open_unix_listen($path);

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file        => "$tmp/notify-events.jsonl.zst",
        transition_sockets => [$path],
    );
    $rec->set_collector_info(uuid => 'UUID-1', name => 'some/test.t');

    my $msgs = drain_socket($listen, sub {
        $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'D'}]}));
        $rec->finalize;
    });

    my ($fin) = grep { $_->{payload}{facet_data}{harness_collector_finalized} } @$msgs;
    ok($fin, "finalization message sent on finalize");
    is($fin->{type}, 'transition', "message wrapped in a transition envelope");
    is($fin->{payload}{facet_data}{harness_collector}{uuid}, 'UUID-1', "carries the collector uuid");
};

subtest connect_at_construction_fails_fast => sub {
    my $err = dies {
        Test2::Harness2::Collector::Recorder->new(
            events_file        => "$tmp/x.jsonl.zst",
            transition_sockets => ["$tmp/does-not-exist.sock"],
        );
    };
    like($err, qr/connect/i, "constructing against a missing socket croaks");
};

subtest writes_to_multiple_sockets => sub {
    my ($p1, $p2) = ("$tmp/m1.sock", "$tmp/m2.sock");
    my $l1 = open_unix_listen($p1);
    my $l2 = open_unix_listen($p2);

    my $rec = Test2::Harness2::Collector::Recorder->new(
        events_file        => "$tmp/multi-events.jsonl.zst",
        transition_sockets => [$p1, $p2],
    );
    $rec->set_collector_info(uuid => 'U2', name => 'n');

    my $c1 = $l1->accept;
    my $c2 = $l2->accept;
    $rec->finalize;

    for my $conn ($c1, $c2) {
        $conn->blocking(0);
        my $fb  = Test2::Harness2::Util::Zstd::FrameBuffer->new;
        my $sel = IO::Select->new($conn);
        while ($sel->can_read(2)) {
            my $buf = '';
            my $n = sysread($conn, $buf, 65536);
            last unless $n;
            $fb->push_bytes($buf);
        }
        my @recs = $fb->drain;
        ok((grep { $_->{payload} =~ /harness_collector_finalized/ } @recs), "both sockets received the finalize");
    }
};

subtest finalize_is_idempotent => sub {
    my $file = "$tmp/idem.jsonl.zst";
    my $rec  = Test2::Harness2::Collector::Recorder->new(events_file => $file);
    $rec->record_event(Test2::Harness2::Event->new(facet_data => {info => [{tag => 'E'}]}));
    $rec->finalize;
    ok(lives { $rec->finalize }, "second finalize is a no-op");
};

subtest abandoned_recorder_closes_sockets => sub {
    my $path   = "$tmp/abandon.sock";
    my $listen = open_unix_listen($path);

    my $rec  = Test2::Harness2::Collector::Recorder->new(
        events_file        => "$tmp/abandon-events.jsonl.zst",
        transition_sockets => [$path],
    );
    my $conn = $listen->accept;

    # Drop the recorder without finalize; DESTROY must close the connection so
    # the peer reaches EOF (a managed monitor relies on this to reap the conn).
    undef $rec;

    $conn->blocking(0);
    my $sel = IO::Select->new($conn);
    ok($sel->can_read(2), "peer becomes readable after recorder is dropped");
    my $buf = '';
    my $n = sysread($conn, $buf, 65536);
    is($n, 0, "peer sees EOF: the abandoned recorder closed its socket");
};

done_testing;
