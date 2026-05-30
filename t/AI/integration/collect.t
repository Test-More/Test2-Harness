use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use POSIX ();
use IO::Select;

use Test2::Harness2::Util::Socket qw/open_unix_listen/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Collector qw/collect spawn_collector/;
use Test2::Harness2::Collector::Auditor;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Collector::Recorder::Test;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json/;

sub read_jsonl_zst ($path) {
    return [] unless -e $path;
    my $r = open_zstd_reader($path);
    my @out;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @out => decode_json($line);
    }
    return \@out;
}

# A child that prints TAP and exits with the requested code.
sub tap_child ($body, $code) {
    return [$^X, '-e', "$body; exit $code"];
}

subtest collect_returns_info => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $info = collect(
        name => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => "$dir/events.jsonl.zst"),
        exec => [$^X, '-e', 'print "hi\n"; exit 3'],
    );

    # info exit mirrors parse_exit's output (sig / err / dmp / all).
    is($info->{exit}{err}, 3,      "info exit.err is the child's exit code");
    is($info->{exit}{sig}, 0,      "info exit.sig is 0 (no signal)");
    is($info->{exit}{dmp}, 0,      "info exit.dmp is 0 (no core dump)");
    is($info->{exit}{all}, 3 << 8, "info exit.all is the raw wait status");

    ok(-s "$dir/events.jsonl.zst", "events file written");
};

subtest collect_applies_env => sub {
    my $dir = tempdir(CLEANUP => 1);

    collect(
        name => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => "$dir/events.jsonl.zst"),
        env  => {T2H2_COLLECT_TEST => 'env-made-it'},
        exec => [$^X, '-e', 'print "VAR=$ENV{T2H2_COLLECT_TEST}\n"'],
    );

    my $events = read_jsonl_zst("$dir/events.jsonl.zst");
    my ($line) = grep { ($_->{facet_data}{from_stream}{details} // '') eq 'VAR=env-made-it' } @$events;
    ok($line, "child saw the env override");
};

subtest collect_with_recorder_instance => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $recorder = Test2::Harness2::Collector::Recorder->new(events_file => "$dir/explicit.jsonl.zst");

    my $info = collect(
        name => "collector-test", recorder => $recorder,
        exec => [$^X, '-e', 'print "via recorder\n"'],
    );

    is($info->{exit}{err}, 0, "clean exit");
    ok(-s "$dir/explicit.jsonl.zst", "explicit recorder's file written");
};

subtest full_test_pipeline_pass => sub {
    my $dir   = tempdir(CLEANUP => 1);
    my $spath = "$dir/transitions.sock";
    my $listen = open_unix_listen($spath);

    my $info = collect(
        name      => "collector-test", is_test => 1, run_uuid => "RUN-1",
        processor => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file        => "$dir/events.jsonl.zst",
            transition_sockets => [$spath],
        ),
        exec => tap_child('print "1..1\nok 1 - good\n"', 0),
    );

    ok($info->{final_state}, "auditor final_state attached to info");
    is($info->{final_state}{pass}, 1, "verdict is pass");

    ok($info->{final_state}{times},             "phase timings present for a real test");
    ok($info->{final_state}{times}{total} >= 0, "total phase duration is non-negative");

    # The recorder connected at construction; accept and drain its frames. Each
    # frame decodes to a {type,payload} envelope; @msgs holds the payloads.
    my $conn = $listen->accept;
    $conn->blocking(0);
    my $fb  = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $sel = IO::Select->new($conn);
    while ($sel->can_read(2)) {
        my $buf = '';
        my $n = sysread($conn, $buf, 65536);
        last unless $n;
        $fb->push_bytes($buf);
    }
    my @msgs = map { decode_json($_->{payload})->{payload} } $fb->drain;

    my %seen = map { $_->{facet_data}{harness_state_transition}{state} => 1 }
        grep { $_->{facet_data}{harness_state_transition} } @msgs;
    ok($seen{starting},                                                "starting transition delivered on the pipe");
    ok($seen{completed},                                               "completed transition delivered on the pipe");
    ok((grep { $_->{facet_data}{harness_final_state} } @msgs),         "final state delivered on the pipe");
    ok((grep { $_->{facet_data}{harness_collector_finalized} } @msgs), "finalization delivered on the pipe");

    # The collector's identity rides on the messages; the start one names it.
    my ($start) = grep { ($_->{facet_data}{harness_state_transition}{state} // '') eq 'starting' } @msgs;
    ok($start->{facet_data}{harness_collector}{uuid}, "start message carries the collector uuid");
    is($start->{facet_data}{harness_collector}{name}, 'collector-test', "start message names the collected thing");
    is($start->{facet_data}{harness_collector}{try},  1,                "test collector start carries try => 1");

    # Identity is sent once: the final-result message carries only the uuid.
    my ($final) = grep { $_->{facet_data}{harness_final_state} } @msgs;
    ok($final->{facet_data}{harness_collector}{uuid},         "final message carries the uuid");
    ok(!exists $final->{facet_data}{harness_collector}{name}, "final message does not repeat the name");

    # Transition / final-state events are routed OUT of the events file.
    my $events = read_jsonl_zst("$dir/events.jsonl.zst");
    ok(
        !(grep { $_->{facet_data}{harness_state_transition} || $_->{facet_data}{harness_final_state} } @$events),
        "events file holds no transition/final-state events",
    );
};

subtest full_test_pipeline_fail => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $info = collect(
        name      => "collector-test", is_test => 1, run_uuid => "RUN-1",
        processor => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file => "$dir/events.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nnot ok 1 - bad\n"', 1),
    );

    is($info->{final_state}{pass}, 0, "verdict is fail");
    ok($info->{final_state}{fail_count} >= 1, "at least one failure counted");
};

subtest spawn_collector_returns_pid_and_verdict_exit => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $pid = spawn_collector(
        name      => "collector-test", is_test => 1, run_uuid => "RUN-1",
        processor => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file => "$dir/p-events.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nok 1\n"', 0),
    );

    ok($pid && $pid > 0, "spawn_collector returned a pid");
    waitpid($pid, 0);
    is($? >> 8, 0, "passing test: collector process exits 0");

    my $pid2 = spawn_collector(
        name      => "collector-test", is_test => 1, run_uuid => "RUN-1",
        processor => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file => "$dir/f-events.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nnot ok 1\n"', 1),
    );

    waitpid($pid2, 0);
    is($? >> 8, 1, "failing test: collector process exits 1");
};

subtest collect_without_recorder => sub {
    # No recorder: nothing is written, but the in-process info summary
    # (including the auditor's verdict) is still returned.
    my $info = collect(
        name      => "collector-test", is_test => 1, run_uuid => "RUN-1",
        processor => ['Test2::Harness2::Collector::Assembler', 'Test2::Harness2::Collector::Auditor'],
        exec      => tap_child('print "1..1\nok 1\n"', 0),
    );

    is($info->{exit}{err},         0, "clean exit with no recorder");
    is($info->{final_state}{pass}, 1, "verdict still available with no recorder");
};

subtest spawn_collector_requires_recorder => sub {
    my $err = dies {
        spawn_collector(exec => [$^X, '-e', 'exit 0']);
    };
    like($err, qr/requires a recorder/, "spawn_collector without a recorder croaks");
};

done_testing;
