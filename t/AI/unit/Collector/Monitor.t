use Test2::V0;
use v5.38;

use File::Temp ();
use IO::Select;
use Compress::Zstd qw/compress/;

use Test2::Harness2::Util::Socket qw/open_unix_listen connect_unix write_frame/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

use Test2::Harness2::Collector::Monitor;

# A monitor folds collector transition messages into per-collector state. It
# runs managed (owns a listening unix socket, reads framed messages on poll())
# or unmanaged (fed already-decoded payloads, or raw frames, from elsewhere).
# Either way it tracks tests/services, their status, and "what changed" deltas,
# and can fan messages out to proxy sockets.

# --- unmanaged-mode helpers: feed already-decoded transition payloads ---

sub payload_for ($facet, %collector) {
    my $fd = {%$facet, harness_collector => {%collector}};
    return {facet_data => $fd};
}

sub feed_start ($mon, %c)        { $mon->feed(payload_for({harness_state_transition => {state => 'starting', stamp => 1}}, %c)) }
sub feed_trans ($mon, $s, $uuid) { $mon->feed(payload_for({harness_state_transition => {state => $s, stamp => 1}}, uuid => $uuid)) }
sub feed_final ($mon, $uuid, $p) { $mon->feed(payload_for({harness_final_state => {pass => $p, fail_count => $p ? 0 : 1}}, uuid => $uuid)) }
sub feed_fin   ($mon, $uuid)     { $mon->feed(payload_for({harness_collector_finalized => {stamp => 1}}, uuid => $uuid)) }

sub unmanaged_monitor () { Test2::Harness2::Collector::Monitor->new }

# Build a {type,payload} transition envelope frame for one collector message.
sub frame_for ($facet, %collector) {
    my $fd = {%$facet, harness_collector => {%collector}};
    return compress(encode_json({type => 'transition', payload => {facet_data => $fd}}));
}

# Read every frame a connection received and replay it into a fresh unmanaged
# downstream monitor (mirrors what a real downstream consumer would do).
sub downstream_from_conn ($conn) {
    $conn->blocking(0);
    my $fb  = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $sel = IO::Select->new($conn);
    while ($sel->can_read(2)) {
        my $buf = '';
        my $n = sysread($conn, $buf, 65536);
        last unless $n;
        $fb->push_bytes($buf);
    }
    my $down = unmanaged_monitor();
    $down->feed(decode_json($_->{payload})->{payload}) for $fb->drain;
    return $down;
}

subtest empty_unmanaged => sub {
    my $mon = unmanaged_monitor();
    is([$mon->tests],    [], "no tests yet");
    is([$mon->services], [], "no services yet");
    is([$mon->poll],     [], "poll on an unmanaged monitor is a no-op");
};

subtest tracks_tests_and_services => sub {
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/foo.t', events_file => '/tmp/foo.jsonl.zst', try => 1);
    feed_start($mon, uuid => 'S1', name => 'my-service');    # no try => service

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
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    is([$mon->new_collectors], ['T1'], "first call reports the new collector");
    is([$mon->new_collectors], [],     "second call reports nothing new");

    feed_start($mon, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1);
    is([$mon->new_collectors], ['T2'], "only the newly-seen collector is reported");
};

subtest failing_and_diagnosing_deltas => sub {
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_trans($mon, 'diagnosing', 'T1');
    feed_trans($mon, 'failing',    'T1');

    is([$mon->new_diagnosing], ['T1'], "diagnosing delta reports T1");
    is([$mon->new_failing],    ['T1'], "failing delta reports T1");
    is([$mon->new_failing],    [],     "failing delta drains");

    ok($mon->collector('T1')->{failing},    "failing flag latched");
    ok($mon->collector('T1')->{diagnosing}, "diagnosing flag latched");
};

subtest final_state_and_exits => sub {
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_final($mon, 'T1', 1);
    feed_trans($mon, 'completed', 'T1');

    is($mon->final_state('T1')->{pass}, 1,          "final state stored");
    is($mon->collector('T1')->{status}, 'complete', "completed collector is complete");
    is([$mon->new_test_exits],          ['T1'],     "test exit delta reports the completed test");
    is([$mon->new_test_exits],          [],         "test exit delta drains");
};

subtest finalized => sub {
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1);
    feed_fin($mon, 'T1');

    is($mon->collector('T1')->{status}, 'finalized', "finalized collector status");
    is([$mon->new_finalized],           ['T1'],      "finalized delta reports T1");
};

subtest tracks_run_uuid => sub {
    my $mon = unmanaged_monitor();
    feed_start($mon, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1');
    feed_start($mon, uuid => 'G1', name => 'svc');    # no run_uuid => global

    is($mon->collector('T1')->{run_uuid}, 'RUN-1', "run_uuid tracked from the start message");
    is($mon->collector('G1')->{run_uuid}, undef,   "a collector with no run_uuid is global");
};

# --- managed mode: the monitor owns a listening socket ---

subtest managed_mode_reads_sockets => sub {
    my $mon  = Test2::Harness2::Collector::Monitor->new(listen => 1);
    my $path = $mon->socket_path;
    ok($path && -S $path, "managed monitor created a listening socket");

    my $client = connect_unix($path);
    $mon->poll;    # accept the pending connection

    write_frame($client, frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));

    my $sel = IO::Select->new($mon->io_handles);
    ok($sel->can_read(2), "monitor handle became readable");
    $mon->poll;

    is([$mon->tests], ['T1'], "managed monitor tracked the collector from the socket");

    write_frame($client, frame_for({harness_state_transition => {state => 'completed', stamp => 1}}, uuid => 'T1'));
    IO::Select->new($mon->io_handles)->can_read(2);
    $mon->poll;
    is($mon->collector('T1')->{status}, 'complete', "later frames on the same connection tracked");
};

subtest managed_mode_listen_path => sub {
    my $dir  = File::Temp::tempdir(CLEANUP => 1);
    my $path = "$dir/mon.sock";
    my $mon  = Test2::Harness2::Collector::Monitor->new(listen => $path);
    is($mon->socket_path, $path, "monitor used the provided listen path");
    ok(-S $path, "bound the provided path");
};

# --- proxy fan-out over sockets (unmanaged source via feed_frame) ---

subtest proxy_forwarding_socket => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(down => $dpath);    # monitor connects to the path
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));

    my $down = downstream_from_conn($dconn);
    is([$down->tests],                 ['T1'],  "message forwarded over the proxy socket");
    is($down->collector('T1')->{name}, 't/a.t', "downstream sees the identity");

    # remove_proxy stops forwarding.
    $mon->remove_proxy('down');
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'completed', stamp => 1}}, uuid => 'T1'));
    my $down2 = downstream_from_conn($dconn);
    is([$down2->tests], [], "no more messages after remove_proxy");
};

subtest proxy_accepts_connected_socket => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/conn.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon  = unmanaged_monitor();
    my $sock = connect_unix($dpath);    # caller-connected socket handle
    $mon->add_proxy(down => $sock);
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));

    my $down = downstream_from_conn($dconn);
    is([$down->tests], ['T1'], "proxy accepts an already-connected socket");
};

subtest multiple_proxies => sub {
    my $dir = File::Temp::tempdir(CLEANUP => 1);

    my $la = open_unix_listen("$dir/a.sock");
    my $lb = open_unix_listen("$dir/b.sock");

    my $mon = unmanaged_monitor();
    $mon->add_proxy(a => "$dir/a.sock");    # connects now
    my $ca = $la->accept;
    $mon->add_proxy(b => "$dir/b.sock");    # connects now
    my $cb = $lb->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));

    is([downstream_from_conn($ca)->tests], ['T1'], "proxy a received the message");
    is([downstream_from_conn($cb)->tests], ['T1'], "proxy b received the message");
};

subtest add_proxy_replays_inflight => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    # An in-flight collector: started, went failing, but not completed.
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'failing', stamp => 1}}, uuid => 'T1'));

    # Add the proxy AFTER the collector is mid-lifecycle.
    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    my $down = downstream_from_conn($dconn);
    is([$down->tests],                 ['T1'],  "replayed the in-flight collector");
    is($down->collector('T1')->{name}, 't/a.t', "downstream has identity from replayed start");
    ok($down->collector('T1')->{failing}, "downstream has the failing state from replay");
};

subtest completed_collectors_not_replayed => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}},
        uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'completed', stamp => 1}}, uuid => 'T1'));

    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    my $down = downstream_from_conn($dconn);
    is([$down->tests], [], "a completed collector is not replayed to a new proxy");
};

subtest proxy_filter_by_run_uuid => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/run1.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(run1 => $dpath, run_uuid => 'RUN-1');
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-2'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'G1', name => 'svc'));

    my $down = downstream_from_conn($dconn);
    is([$down->collectors], ['T1'], "proxy only forwarded the RUN-1 collector");
};

subtest proxy_filter_global => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/g.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(g => $dpath, global => 1);
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'G1', name => 'svc'));

    my $down = downstream_from_conn($dconn);
    is([$down->collectors], ['G1'], "global proxy only forwarded the run-less collector");
};

subtest proxy_filter_global_plus_run => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/mix.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(mix => $dpath, global => 1, run_uuid => 'RUN-1');
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-2'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'G1', name => 'svc'));

    my $down = downstream_from_conn($dconn);
    is([sort $down->collectors], ['G1', 'T1'], "global+run proxy forwarded the global and RUN-1 collectors");
};

subtest proxy_filter_run_uuids_list => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/multi.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(multi => $dpath, run_uuids => ['RUN-1', 'RUN-3']);
    my $dconn = $dlisten->accept;

    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-2'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T3', name => 't/c.t', events_file => '/tmp/c', try => 1, run_uuid => 'RUN-3'));

    my $down = downstream_from_conn($dconn);
    is([sort $down->collectors], ['T1', 'T3'], "run_uuids list forwarded both named runs");
};

subtest proxy_filter_replay_honors_filter => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/run1.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    # In-flight collectors of two runs before the proxy is added.
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T1', name => 't/a.t', events_file => '/tmp/a', try => 1, run_uuid => 'RUN-1'));
    $mon->feed_frame(frame_for({harness_state_transition => {state => 'starting', stamp => 1}}, uuid => 'T2', name => 't/b.t', events_file => '/tmp/b', try => 1, run_uuid => 'RUN-2'));

    $mon->add_proxy(run1 => $dpath, run_uuid => 'RUN-1');
    my $dconn = $dlisten->accept;

    my $down = downstream_from_conn($dconn);
    is([$down->collectors], ['T1'], "replay to a filtered proxy only includes matching runs");
};

# --- runs + jobs ---

sub feed_run ($mon, %f) { $mon->feed({facet_data => {harness_run => {%f}}}) }
sub feed_job ($mon, %f) { $mon->feed({facet_data => {harness_job => {%f}}}) }

subtest run_lifecycle_merge => sub {
    my $mon = unmanaged_monitor();

    feed_run($mon, run_uuid => 'R1', state => 'queued', job_uuids => ['J1', 'J2'], job_count => 2);
    is($mon->run('R1')->{state}, 'queued', "run starts queued");
    is($mon->run('R1')->{job_uuids}, ['J1', 'J2'], "job list recorded");
    is([$mon->runs], ['R1'], "run is tracked");

    feed_run($mon, run_uuid => 'R1', state => 'running');
    is($mon->run('R1')->{state}, 'running', "merge updates state");
    is($mon->run('R1')->{job_count}, 2, "merge keeps prior fields");

    feed_run($mon, run_uuid => 'R1', state => 'complete', completed => 2, passed => 2, failed => 0, pass => 1);
    is($mon->run('R1')->{state}, 'complete', "run completes");
    is($mon->run('R1')->{pass}, 1, "aggregate pass recorded");
    ok($mon->run('R1')->{done_stamp}, "completion stamped");
};

subtest job_announce_then_collector_folds => sub {
    my $mon = unmanaged_monitor();

    feed_job($mon, job_uuid => 'J1', run_uuid => 'R1', spec => {relative => 't/a.t', category => 'general'});
    is([$mon->jobs], ['J1'], "job tracked from announce");
    is($mon->job('J1')->{status}, 'queued', "job starts queued");
    is($mon->job('J1')->{spec}{relative}, 't/a.t', "spec carried");

    # The collector shares the job uuid; its messages fold into the job entry.
    feed_start($mon, uuid => 'J1', name => 't/a.t', events_file => '/tmp/a', try => 1,
        config => {is_test => 1, exec => ['perl', 't/a.t']});

    is($mon->job('J1')->{status}, 'running', "collector start folds into the job");
    is($mon->job('J1')->{events_file}, '/tmp/a', "job gains events_file from collector");
    is($mon->job('J1')->{config}{exec}, ['perl', 't/a.t'], "spawn config folded into the job");
    is($mon->job('J1')->{spec}{relative}, 't/a.t', "spec still present after fold");
    is($mon->collector('J1'), $mon->job('J1'), "collector(uuid) resolves to the job entry");

    feed_final($mon, 'J1', 1);
    feed_fin($mon, 'J1');
    is($mon->job('J1')->{status}, 'finalized', "job finalizes via collector message");
    is($mon->final_state('J1')->{pass}, 1, "final state on the job");
    ok($mon->job('J1')->{done_stamp}, "job finalization stamped");
};

subtest announce_forwards_runs_and_jobs => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    $mon->announce({harness_run => {run_uuid => 'R1', state => 'queued', job_uuids => ['J1'], job_count => 1}});
    $mon->announce({harness_job => {job_uuid => 'J1', run_uuid => 'R1', spec => {relative => 't/a.t'}}});

    my $down = downstream_from_conn($dconn);
    is([$down->runs], ['R1'], "run forwarded to downstream");
    is($down->run('R1')->{state}, 'queued', "downstream sees run state");
    is([$down->jobs], ['J1'], "job forwarded to downstream");
    is($down->job('J1')->{spec}{relative}, 't/a.t', "downstream sees job spec");
};

subtest announce_replays_inflight_to_late_proxy => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->announce({harness_run => {run_uuid => 'R1', state => 'running', job_count => 1}});
    $mon->announce({harness_job => {job_uuid => 'J1', run_uuid => 'R1', spec => {relative => 't/a.t'}}});

    # Proxy added after the announces: replay should catch it up.
    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    my $down = downstream_from_conn($dconn);
    is($down->run('R1')->{state}, 'running', "in-flight run replayed to late proxy");
    is([$down->jobs], ['J1'], "in-flight job replayed to late proxy");
};

subtest sweep_removes_completed_after_ttl => sub {
    my $mon = Test2::Harness2::Collector::Monitor->new(completed_ttl => 100);

    feed_run($mon, run_uuid => 'R1', state => 'complete', completed => 1, passed => 1);
    feed_job($mon, job_uuid => 'J1', run_uuid => 'R1');
    feed_start($mon, uuid => 'J1', name => 't/a.t', try => 1);
    feed_fin($mon, 'J1');

    feed_run($mon, run_uuid => 'R2', state => 'running');    # in flight, no done_stamp

    my $done = $mon->run('R1')->{done_stamp};

    $mon->sweep($done + 50);     # within ttl
    ok($mon->run('R1'),  "completed run kept within ttl");
    ok($mon->job('J1'),  "finalized job kept within ttl");

    $mon->sweep($done + 201);    # past ttl
    ok(!$mon->run('R1'), "completed run reaped past ttl");
    ok(!$mon->job('J1'), "finalized job reaped past ttl");
    ok($mon->run('R2'),  "in-flight run never reaped");
};

subtest system_load_stored => sub {
    my $mon = unmanaged_monitor();
    is($mon->system_load, undef, "no system load yet");

    $mon->feed({facet_data => {harness_system => {cpu_pct => 12.5, ncpu => 4, mem_pct => 30}}});
    is($mon->system_load->{cpu_pct}, 12.5, "system load stored");
    is($mon->system_load->{ncpu}, 4, "ncpu stored");

    # Replaced, not accumulated.
    $mon->feed({facet_data => {harness_system => {cpu_pct => 90, ncpu => 4}}});
    is($mon->system_load->{cpu_pct}, 90, "latest snapshot replaces the prior one");
};

subtest system_load_forwarded_live => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    $mon->announce({harness_system => {cpu_pct => 33, ncpu => 8}});

    my $down = downstream_from_conn($dconn);
    is($down->system_load->{cpu_pct}, 33, "system load forwarded to a live proxy");
};

subtest system_load_replayed_to_late_proxy => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->announce({harness_system => {cpu_pct => 7, ncpu => 1}});
    $mon->announce({harness_system => {cpu_pct => 8, ncpu => 1}});

    # Proxy joins late: it should get the latest snapshot only.
    $mon->add_proxy(down => $dpath);
    my $dconn = $dlisten->accept;

    my $down = downstream_from_conn($dconn);
    is($down->system_load->{cpu_pct}, 8, "latest system snapshot replayed to a late proxy");
};

subtest system_load_ignores_run_filter => sub {
    my $dir     = File::Temp::tempdir(CLEANUP => 1);
    my $dpath   = "$dir/down.sock";
    my $dlisten = open_unix_listen($dpath);

    my $mon = unmanaged_monitor();
    $mon->add_proxy(down => $dpath, run_uuid => 'RUN-1');    # run-scoped filter
    my $dconn = $dlisten->accept;

    $mon->announce({harness_system => {cpu_pct => 5, ncpu => 2}});

    my $down = downstream_from_conn($dconn);
    is($down->system_load->{cpu_pct}, 5, "system load reaches even a run-filtered proxy");
};

subtest sweep_disabled_when_ttl_zero => sub {
    my $mon = Test2::Harness2::Collector::Monitor->new(completed_ttl => 0);
    feed_run($mon, run_uuid => 'R1', state => 'complete');
    $mon->sweep($mon->run('R1')->{done_stamp} + 1_000_000);
    ok($mon->run('R1'), "ttl 0 disables reaping");
};

done_testing;
