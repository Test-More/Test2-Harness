use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Atomic::Pipe;
use POSIX       ();
use Time::HiRes ();

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Recorder;
use Test2::Harness2::Util::Zstd qw/open_zstd_reader/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

# Mirror Test2::Harness2::Util::EventEmitter's pipe attach: dup the fd in
# place, switch to mixed-data mode, then enable zstd to match the collector.
sub mixed_pipe ($fh) {
    my $p = Atomic::Pipe->from_fh('>&=', $fh);
    $p->set_mixed_data_mode();
    $p->set_compression('zstd');
    return $p;
}

sub read_events ($path) {
    my $r = open_zstd_reader($path);
    my @events;
    while (defined(my $line = $r->readline)) {
        next unless length $line;
        push @events => decode_json($line);
    }
    return @events;
}

# Spawn a short-lived process that is reparented to init, so that once it
# exits it is reaped cleanly and kill(0, $pid) reports it gone (ESRCH). We
# double-fork and reap the intermediate ourselves; the grandchild's pid comes
# back over a pipe.
sub spawn_orphan ($lifetime) {
    pipe(my $rh, my $wh) or die "pipe: $!";

    my $mid = fork // die "fork: $!";
    if ($mid == 0) {
        close $rh;
        my $gc = fork // POSIX::_exit(1);
        if ($gc) {
            syswrite($wh, "$gc\n");
            POSIX::_exit(0);
        }
        close $wh;
        Time::HiRes::sleep($lifetime);
        POSIX::_exit(0);
    }

    close $wh;
    waitpid($mid, 0);
    chomp(my $pid = <$rh>);
    close $rh;
    return $pid;
}

subtest exec_command => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    my $exit = Test2::Harness2::Collector->start(
        name         => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-e', 'print "hello stdout\n"; print STDERR "oops stderr\n"; exit 3'],
    );

    is($exit, 0, "collector returned 0 (clean pipeline run)");
    ok(-s $ef, "events file was written and is non-empty");

    my @events = read_events($ef);

    my ($stdout) = grep { ($_->{facet_data}{from_stream}{source} // '') eq 'STDOUT' } @events;
    my ($stderr) = grep { ($_->{facet_data}{from_stream}{source} // '') eq 'STDERR' } @events;
    my ($exit_e) = grep { $_->{facet_data}{harness_process_exit} } @events;

    is($stdout->{facet_data}{from_stream}{details}, "hello stdout", "captured stdout line");
    is($stderr->{facet_data}{from_stream}{details}, "oops stderr",  "captured stderr line");

    ok($exit_e, "got a harness_process_exit event");
    is($exit_e->{facet_data}{harness_process_exit}{all} >> 8, 3, "exit event carries exit code 3");
};

subtest run_sub => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    my $ran  = 0;
    my $exit = Test2::Harness2::Collector->start(
        name    => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        run_sub => sub ($guard) { $ran = 1; print "from the sub\n"; },
    );

    is($exit, 0, "collector returned 0 for run_sub");

    my @events = read_events($ef);
    my ($line) = grep { ($_->{facet_data}{from_stream}{details} // '') eq 'from the sub' } @events;
    ok($line, "captured the run_sub's stdout line");

    my ($exit_e) = grep { $_->{facet_data}{harness_process_exit} } @events;
    is($exit_e->{facet_data}{harness_process_exit}{all}, 0, "run_sub child exited 0");
};

subtest burst_passthrough => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    # New wire protocol: the event is a JSON hash with no sync field; the
    # sync marker is a separate JSON array [pid, ordinal] written to both
    # handles. Markers are never recorded.
    my $exit = Test2::Harness2::Collector->start(
        name    => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        run_sub => sub ($guard) {
            my $out = mixed_pipe(\*STDOUT);
            my $err = mixed_pipe(\*STDERR);

            my $payload = encode_json({
                facet_data => {info => [{tag => 'NOTE', details => 'burst hi'}]},
            });
            my $sync = encode_json([$$, 0]);

            $out->write_message($payload);
            $out->write_message($sync);
            $err->write_message($sync);
        },
    );

    is($exit, 0, "collector returned 0 for burst run");

    my @events = read_events($ef);
    my ($burst) = grep { ($_->{facet_data}{info}[0]{tag} // '') eq 'NOTE' } @events;

    ok($burst, "burst event reached the events file");
    is($burst->{facet_data}{info}[0]{details}, 'burst hi', "burst payload preserved");
    ok(!exists $burst->{event_id}, "no event_id stamped on the event");

    ok(
        !(grep { ref $_ eq 'ARRAY' } @events),
        "sync markers (arrays) were not recorded as events",
    );
};

subtest exit_details => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    Test2::Harness2::Collector->start(
        name         => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        exec_command => [$^X, '-e', 'exit 3'],
    );

    my @events   = read_events($ef);
    my ($exit_e) = grep { $_->{facet_data}{harness_process_exit} } @events;
    my $f        = $exit_e->{facet_data}{harness_process_exit};

    is($f->{err},      3, "decoded exit code (err) is 3");
    is($f->{sig},      0, "no terminating signal");
    is($f->{dmp},      0, "no core dump");
    is($f->{all} >> 8, 3, "raw wait status still present");

    ok(defined $f->{times},                  "timing block present");
    ok(defined $f->{times}{child}{user},     "child user cpu time present");
    ok(defined $f->{times}{child}{system},   "child system cpu time present");
    ok(defined $f->{times}{collector}{user}, "collector user cpu time present");
    ok(defined $f->{times}{wall},            "child wall time present");
    ok($f->{times}{wall} >= 0,               "child wall time is non-negative");

    if (eval { require BSD::Resource; 1 }) {
        ok($f->{memory}, "memory facet present when BSD::Resource is available");
        is($f->{memory}{unit}, 'KB', "memory unit is KB");
        ok($f->{memory}{child_maxrss} > 0, "child_maxrss is positive");
    }
    else {
        ok(!exists $f->{memory}, "memory facet omitted without BSD::Resource");
    }
};

subtest watch_parent_pid => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $ef  = "$dir/events.jsonl.zst";

    my $ppid = spawn_orphan(0.3);

    my $start = Time::HiRes::time();
    my $exit  = Test2::Harness2::Collector->start(
        name             => "collector-test", recorder => Test2::Harness2::Collector::Recorder->new(events_file => $ef),
        watch_parent_pid => $ppid,
        run_sub          => sub ($guard) { Time::HiRes::sleep(30) },
    );
    my $elapsed = Time::HiRes::time() - $start;

    is($exit, 0, "collector returned 0 (clean pipeline run)");
    ok($elapsed < 10, "collector stopped early on parent death, not after the 30s child sleep")
        or diag("elapsed: $elapsed");

    my @events = read_events($ef);

    my ($pe) = grep { $_->{facet_data}{harness_parent_exit} } @events;
    ok($pe, "got a harness_parent_exit event");
    is($pe->{facet_data}{harness_parent_exit}{parent_pid}, $ppid, "event names the watched parent pid");

    my ($exit_e) = grep { $_->{facet_data}{harness_process_exit} } @events;
    is($exit_e->{facet_data}{harness_process_exit}{parent_exited}, 1,  "exit event flags parent_exited");
    is($exit_e->{facet_data}{harness_process_exit}{sig},           15, "child was terminated with SIGTERM");
};

subtest required_and_mutually_exclusive => sub {
    like(
        dies { Test2::Harness2::Collector->new(exec_command => ['x']) },
        qr/name is a required/,
        "name is required",
    );

    like(
        dies {
            Test2::Harness2::Collector->new(name => 'x', exec_command => ['x'], run_sub => sub { })
        },
        qr/mutually exclusive/,
        "exec_command and run_sub are mutually exclusive",
    );

    like(
        dies { Test2::Harness2::Collector->new(name => 'x') },
        qr/exec_command or run_sub/,
        "one of exec_command / run_sub is required",
    );

    ok(
        lives { Test2::Harness2::Collector->new(name => 'x', exec_command => ['x']) },
        "no recorder is allowed (an in-process run still returns its info)",
    );
};

done_testing;
