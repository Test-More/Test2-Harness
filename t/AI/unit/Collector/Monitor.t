use Test2::V0;
use v5.38;

use Atomic::Pipe;
use IO::Select;

use Test2::Harness2::Util::IPC qw/atomic_pipe_compression_args/;
use Test2::Harness2::Util::JSON qw/encode_json/;

use Test2::Harness2::Collector::Monitor;

# The monitor consumes a transition pipe that one or more collectors write to.
# poll() reads whatever is available without blocking, updates its per-collector
# state, and returns the payloads it read. It also answers "what changed since
# last time" questions (new collectors, new failing, new exits, ...).

# Build a recorder-shaped notification message and write it to the pipe.
sub send_msg ($w, $facet, %collector) {
    my $fd = {%$facet, harness_collector => {%collector}};
    $w->write_message(encode_json({facet_data => $fd}));
    return;
}

sub start_msg     ($w, %c)        { send_msg($w, {harness_state_transition => {state => 'starting', stamp => 1}}, %c) }
sub transition    ($w, $s, $uuid) { send_msg($w, {harness_state_transition => {state => $s, stamp => 1}}, uuid => $uuid) }
sub final_msg     ($w, $uuid, $p) { send_msg($w, {harness_final_state => {pass => $p, fail_count => $p ? 0 : 1}}, uuid => $uuid, name => 'n', ($p ? () : ())) }
sub finalized_msg ($w, $uuid)     { send_msg($w, {harness_collector_finalized => {stamp => 1}}, uuid => $uuid) }

sub new_monitor () {
    my ($r, $w) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    my $mon = Test2::Harness2::Collector::Monitor->new(pipe => $r);
    return ($mon, $w);
}

subtest poll_empty => sub {
    my ($mon, $w) = new_monitor();
    is([$mon->poll],     [], "poll with nothing available returns an empty list");
    is([$mon->tests],    [], "no tests yet");
    is([$mon->services], [], "no services yet");
};

subtest poll_contexts => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/foo.t', events_file => '/tmp/foo.jsonl.zst', try => 1);

    my @got = $mon->poll;
    is(scalar(@got),                                         1,          "list context returns the payloads");
    is($got[0]{facet_data}{harness_state_transition}{state}, 'starting', "payload is the decoded message");

    transition($w, 'completed', 'T1');
    my $n = $mon->poll;
    is($n, 1, "scalar context returns the message count");

    # void context still updates state but returns nothing.
    transition($w, 'failing', 'T1');
    $mon->poll;
    ok($mon->collector('T1')->{failing}, "void-context poll still updated state");
};

subtest tracks_tests_and_services => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/foo.t', events_file => '/tmp/foo.jsonl.zst', try => 1);
    start_msg($w, uuid => 'S1', name => 'my-service');    # no try => service
    $mon->poll;

    is([sort $mon->tests],    ['T1'], "T1 categorized as a test (has try)");
    is([sort $mon->services], ['S1'], "S1 categorized as a service (no try)");

    my $t = $mon->collector('T1');
    is($t->{name},              't/foo.t',            "test name tracked");
    is($t->{events_file},       '/tmp/foo.jsonl.zst', "events file tracked");
    is($t->{try},               1,                    "try tracked");
    is($t->{status},            'running',            "a started collector is running");
    is($mon->events_file('T1'), '/tmp/foo.jsonl.zst', "events_file query works");
};

subtest new_collectors_delta => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    $mon->poll;
    is([$mon->new_collectors], ['T1'], "first call reports the new collector");
    is([$mon->new_collectors], [],     "second call reports nothing new");

    start_msg($w, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1);
    $mon->poll;
    is([$mon->new_collectors], ['T2'], "only the newly-seen collector is reported");
};

subtest failing_and_diagnosing_deltas => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    transition($w, 'diagnosing', 'T1');
    transition($w, 'failing',    'T1');
    $mon->poll;

    is([$mon->new_diagnosing], ['T1'], "diagnosing delta reports T1");
    is([$mon->new_failing],    ['T1'], "failing delta reports T1");
    is([$mon->new_failing],    [],     "failing delta drains");

    ok($mon->collector('T1')->{failing},    "failing flag latched");
    ok($mon->collector('T1')->{diagnosing}, "diagnosing flag latched");
};

subtest final_state_and_exits => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    final_msg($w, 'T1', 1);
    transition($w, 'completed', 'T1');
    $mon->poll;

    is($mon->final_state('T1')->{pass}, 1,          "final state stored");
    is($mon->collector('T1')->{status}, 'complete', "completed collector is complete");
    is([$mon->new_test_exits],          ['T1'],     "test exit delta reports the completed test");
    is([$mon->new_test_exits],          [],         "test exit delta drains");
};

subtest finalized => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    finalized_msg($w, 'T1');
    $mon->poll;

    is($mon->collector('T1')->{status}, 'finalized', "finalized collector status");
    is([$mon->new_finalized],           ['T1'],      "finalized delta reports T1");
};

subtest exposes_handle_for_select => sub {
    my ($mon, $w) = new_monitor();
    my $sel = IO::Select->new($mon->pipe->rh);

    ok(!$sel->can_read(0), "nothing to read yet");
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    ok($sel->can_read(2), "select sees the pipe become readable");

    $mon->poll;
    is([$mon->tests], ['T1'], "after select+poll the message is consumed");
};

subtest proxy_forwarding => sub {
    my ($mon, $w) = new_monitor();

    # A proxy is a write-end the monitor forwards every message to; here the
    # read end feeds a second, downstream monitor.
    my ($dr, $dw) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    $mon->add_proxy(down => $dw);

    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    $mon->poll;

    my $down = Test2::Harness2::Collector::Monitor->new(pipe => $dr);
    $down->poll;
    is([$down->tests],                 ['T1'],  "message forwarded to the proxy and consumed downstream");
    is($down->collector('T1')->{name}, 't/a.t', "downstream sees the identity");

    # remove_proxy stops forwarding.
    $mon->remove_proxy('down');
    transition($w, 'completed', 'T1');
    $mon->poll;
    $down->poll;
    isnt($down->collector('T1')->{status}, 'complete', "no more messages after remove_proxy");
};

subtest multiple_proxies => sub {
    my ($mon, $w)  = new_monitor();
    my ($ar,  $aw) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    my ($br,  $bw) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    $mon->add_proxy(a => $aw);
    $mon->add_proxy(b => $bw);

    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    $mon->poll;

    for my $pair (['a', $ar], ['b', $br]) {
        my ($n, $r) = @$pair;
        my $down = Test2::Harness2::Collector::Monitor->new(pipe => $r);
        $down->poll;
        is([$down->tests], ['T1'], "proxy $n received the message");
    }
};

subtest add_proxy_replays_inflight => sub {
    my ($mon, $w) = new_monitor();

    # An in-flight collector: started, went failing, but not completed.
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    transition($w, 'failing', 'T1');
    $mon->poll;

    # Add the proxy AFTER the collector is mid-lifecycle.
    my ($dr, $dw) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    $mon->add_proxy(down => $dw);

    my $down = Test2::Harness2::Collector::Monitor->new(pipe => $dr);
    $down->poll;

    # The downstream monitor must have the full state, not a half-lifecycle.
    is([$down->tests],                 ['T1'],  "replayed the in-flight collector");
    is($down->collector('T1')->{name}, 't/a.t', "downstream has identity from replayed start");
    ok($down->collector('T1')->{failing}, "downstream has the failing state from replay");

    # Subsequent live messages flow through too.
    transition($w, 'completed', 'T1');
    $mon->poll;
    $down->poll;
    is($down->collector('T1')->{status}, 'complete', "live messages forwarded after replay");
};

subtest completed_collectors_not_replayed => sub {
    my ($mon, $w) = new_monitor();
    start_msg($w, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    transition($w, 'completed', 'T1');
    $mon->poll;

    my ($dr, $dw) = Atomic::Pipe->pair(atomic_pipe_compression_args());
    $mon->add_proxy(down => $dw);
    $dw->close;    # nothing should have been written; close so reads EOF

    my $down = Test2::Harness2::Collector::Monitor->new(pipe => $dr);
    $down->poll;
    is([$down->tests], [], "a completed collector is not replayed to a new proxy");
};

done_testing;
