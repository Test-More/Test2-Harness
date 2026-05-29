use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use POSIX ();

use Test2::Harness2::Collector qw/collect spawn_collector/;
use Test2::Harness2::Collector::Auditor::Test;
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
        events_file => "$dir/events.jsonl.zst",
        exec        => [$^X, '-e', 'print "hi\n"; exit 3'],
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
        events_file => "$dir/events.jsonl.zst",
        env         => {T2H2_COLLECT_TEST => 'env-made-it'},
        exec        => [$^X, '-e', 'print "VAR=$ENV{T2H2_COLLECT_TEST}\n"'],
    );

    my $events = read_jsonl_zst("$dir/events.jsonl.zst");
    my ($line) = grep { ($_->{facet_data}{from_stream}{details} // '') eq 'VAR=env-made-it' } @$events;
    ok($line, "child saw the env override");
};

subtest collect_with_recorder_instance => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $recorder = Test2::Harness2::Collector::Recorder->new(events_file => "$dir/explicit.jsonl.zst");

    my $info = collect(
        recorder => $recorder,
        exec     => [$^X, '-e', 'print "via recorder\n"'],
    );

    is($info->{exit}{err}, 0, "clean exit");
    ok(-s "$dir/explicit.jsonl.zst", "explicit recorder's file written");
};

subtest full_test_pipeline_pass => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $info = collect(
        is_test   => 1,
        processor => 'Test2::Harness2::Collector::Auditor::Test',
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file      => "$dir/events.jsonl.zst",
            transitions_file => "$dir/transitions.jsonl.zst",
            state_file       => "$dir/state.jsonl.zst",
            touchfile        => "$dir/touch",
        ),
        exec => tap_child('print "1..1\nok 1 - good\n"', 0),
    );

    ok($info->{final_state}, "auditor final_state attached to info");
    is($info->{final_state}{pass}, 1, "verdict is pass");

    my $state = read_jsonl_zst("$dir/state.jsonl.zst");
    is(scalar(@$state), 1, "one final-state row in the state file");
    is($state->[0]{facet_data}{harness_final_state}{pass}, 1, "state file records pass");

    my $trans = read_jsonl_zst("$dir/transitions.jsonl.zst");
    my %seen  = map { $_->{facet_data}{harness_state_transition}{state} => 1 } @$trans;
    ok($seen{starting},  "starting transition recorded");
    ok($seen{completed}, "completed transition recorded");

    ok(-e "$dir/touch", "touchfile touched");

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
        is_test   => 1,
        processor => 'Test2::Harness2::Collector::Auditor::Test',
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file      => "$dir/events.jsonl.zst",
            transitions_file => "$dir/transitions.jsonl.zst",
            state_file       => "$dir/state.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nnot ok 1 - bad\n"', 1),
    );

    is($info->{final_state}{pass}, 0, "verdict is fail");
    ok($info->{final_state}{fail_count} >= 1, "at least one failure counted");
};

subtest spawn_collector_returns_pid_and_verdict_exit => sub {
    my $dir = tempdir(CLEANUP => 1);

    my $pid = spawn_collector(
        is_test   => 1,
        processor => 'Test2::Harness2::Collector::Auditor::Test',
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file      => "$dir/p-events.jsonl.zst",
            transitions_file => "$dir/p-transitions.jsonl.zst",
            state_file       => "$dir/p-state.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nok 1\n"', 0),
    );

    ok($pid && $pid > 0, "spawn_collector returned a pid");
    waitpid($pid, 0);
    is($? >> 8, 0, "passing test: collector process exits 0");

    my $pid2 = spawn_collector(
        is_test   => 1,
        processor => 'Test2::Harness2::Collector::Auditor::Test',
        recorder  => Test2::Harness2::Collector::Recorder::Test->new(
            events_file      => "$dir/f-events.jsonl.zst",
            transitions_file => "$dir/f-transitions.jsonl.zst",
            state_file       => "$dir/f-state.jsonl.zst",
        ),
        exec => tap_child('print "1..1\nnot ok 1\n"', 1),
    );

    waitpid($pid2, 0);
    is($? >> 8, 1, "failing test: collector process exits 1");
};

done_testing;
