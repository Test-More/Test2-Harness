use Test2::V0;
use File::Temp qw/tempdir/;
use POSIX qw/:sys_wait_h/;
use Config;
use Time::HiRes qw/sleep/;
use Test2::Harness2::Util::JSON qw/decode_json encode_json/;

use Test2::Harness2::Collector;
use Test2::Harness2::Collector::Test;
use Test2::Harness2::Collector::Logger::JSONL;

# Minimal logger that consumes the role and leaves metadata() at its
# role default (undef). Used to assert that loggers with no metadata
# get omitted from the collector_artifacts payload.
{

    package T2H2_SilentLogger;
    use Object::HashBase;
    use Role::Tiny::With;
    sub update_style { 'append' }
    sub log_reader   { undef }
    sub ready        { 0 }
    sub fetch_events { () }
    sub fetch_state  { undef }
    with 'Test2::Harness2::Role::Collector::Logger';
    sub log_events { 0 }
    sub log_event  { }
    sub shutdown   { }
}

# The collector now unconditionally fires a collector_artifacts IPC message after
# its loggers start.  The real bus is not running under these unit tests, so
# stub the handle out to keep the tests quiet and fast.  Individual subtests
# below install their own overrides when they want to observe the message.
BEGIN {
    require IPC::Manager;
    no warnings 'once', 'redefine';
    *IPC::Manager::connect = sub {
        return bless {}, 'T2H2_TestNoopClient';
    };
    *T2H2_TestNoopClient::send_message       = sub { return };
    *T2H2_TestNoopClient::try_send_message   = sub { return 1 };
    *T2H2_TestNoopClient::peer_active        = sub { 1 };
    *T2H2_TestNoopClient::disconnect         = sub { return };
    *T2H2_TestNoopClient::pending_sends      = sub { 0 };
    *T2H2_TestNoopClient::have_pending_sends = sub { 0 };
    *T2H2_TestNoopClient::drain_pending      = sub { 0 };
    *T2H2_TestNoopClient::have_writable_handles = sub { 0 };
    *T2H2_TestNoopClient::writable_handles   = sub { () };
    *T2H2_TestNoopClient::set_send_blocking  = sub { return };
}

my $IS_WIN32 = $^O eq 'MSWin32';
my $CAN_FORK = $Config{d_fork};
my $CAN_FIFO = !$IS_WIN32 && eval { require POSIX; POSIX->can('mkfifo') };

my $tmpdir = tempdir(CLEANUP => 1);

sub read_events {
    my ($file) = @_;
    open(my $fh, '<', $file) or die "Could not open $file: $!";
    my @events;
    while (my $line = <$fh>) {
        chomp $line;
        push @events, decode_json($line);
    }
    close($fh);
    return @events;
}

sub find_events {
    my ($events, %filter) = @_;
    my @found;
    for my $e (@$events) {
        my $match = 1;
        if ($filter{stream}) {
            $match = 0 unless ($e->{facet_data}{from_stream}{source} // '') eq uc($filter{stream});
        }
        if ($filter{exit}) {
            $match = 0 unless exists $e->{facet_data}{harness_process_exit};
        }
        push @found, $e if $match;
    }
    return @found;
}

# ===========================================================================
# Launch mode tests (all platforms)
# ===========================================================================

subtest 'launch - basic stdout/stderr' => sub {
    my $output = "$tmpdir/a_basic.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print "hello stdout\n"; print STDERR "hello stderr\n"'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    ok($collector,      "created collector");
    ok($collector->pid, "has collector pid");
    isa_ok($collector, 'Test2::Harness2::Collector::Handle');

    my $exit = $collector->wait();
    is($exit, 0, "collector exited cleanly");

    my @events = read_events($output);
    ok(@events >= 2, "got at least 2 events");

    my ($out_ev) = find_events(\@events, stream => 'stdout');
    ok($out_ev, "found stdout event");
    like($out_ev->{facet_data}{from_stream}{details}, qr/hello stdout/, "stdout content correct");

    my ($err_ev) = find_events(\@events, stream => 'stderr');
    ok($err_ev, "found stderr event");
    like($err_ev->{facet_data}{from_stream}{details}, qr/hello stderr/, "stderr content correct");
    is($err_ev->{facet_data}{info}[0]{debug}, 1, "stderr marked as debug");

    my ($exit_ev) = find_events(\@events, exit => 1);
    ok($exit_ev, "found exit event");
    is($exit_ev->{facet_data}{harness_process_exit}{err}, 0, "exit status 0");
};

subtest 'launch - exit code capture' => sub {
    my $output = "$tmpdir/a_exit.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'exit 42'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $exit = $collector->wait();

    is($exit >> 8, 42, "collector mirrored child's exit code 42");

    my @events = read_events($output);
    my ($exit_ev) = find_events(\@events, exit => 1);
    ok($exit_ev, "found exit event");
    is($exit_ev->{facet_data}{harness_process_exit}{err}, 42, "exit status 42");
};

subtest 'launch - loop yields CPU while child is idle' => sub {
    skip_all "fork required"               unless $CAN_FORK;
    skip_all "/proc/\$pid/status required" unless -e "/proc/$$/status";

    my $output = "$tmpdir/a_idle_yield.jsonl";

    # Child sleeps a while before producing output, giving the collector a
    # long stretch with nothing on either pipe. If the collector's read loop
    # does non-blocking reads without a select(), it will tight-spin over
    # that stretch and its voluntary_ctxt_switches will stay at whatever
    # value it had when it entered the loop. A select()-paced loop will
    # block on the idle pipes and accrue voluntary context switches.
    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'sleep 2; print "done\n"'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $cpid = $collector->pid;
    ok($cpid, "have collector pid");

    my $read_vcs = sub {
        open(my $fh, '<', "/proc/$cpid/status") or return undef;
        while (my $line = <$fh>) {
            return $1 if $line =~ /^voluntary_ctxt_switches:\s+(\d+)/;
        }
        return undef;
    };

    # Let the collector finish setup and land in its read loop.
    sleep 0.2;
    my $before = $read_vcs->();

    # Sit idle while the child is asleep; a busy-looping collector accrues
    # no voluntary yields here.
    sleep 0.8;
    my $after = $read_vcs->();

    my $exit = $collector->wait();
    is($exit, 0, "collector exited cleanly");

    ok(defined $before && defined $after, "read voluntary_ctxt_switches");
    my $delta = $after - $before;
    cmp_ok($delta, '>', 0, "collector yielded CPU while child was idle (vcs delta=$delta)");
};

subtest 'launch - signal mirroring' => sub {
    skip_all "fork/signal mirroring not applicable on Win32" if $IS_WIN32;

    my $output = "$tmpdir/a_signal.jsonl";

    # Child kills itself with SIGUSR1 (chosen because no test framework or
    # harness machinery handles it by default). Collector should observe the
    # signal exit and re-raise the same signal in itself, so $? on the
    # collector's wait-status carries the signal too.
    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'kill USR1 => $$; sleep 5'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $exit = $collector->wait();
    my $sig  = $exit & 127;

    use Config;
    my @names = split ' ', $Config{sig_name};
    is($names[$sig], 'USR1', "collector wait-status carries the same signal as the child");

    my @events = read_events($output);
    my ($exit_ev) = find_events(\@events, exit => 1);
    ok($exit_ev, "found exit event");
    is($names[$exit_ev->{facet_data}{harness_process_exit}{sig}], 'USR1', "exit event carries the signal");
};

# Minimal auditor stub for tests that need to drive the collector's
# auditor-failing exit-code path without pulling in the full Test auditor.
{

    package T2H2_Test_StubAuditor;
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Auditor';
    sub new              { my $c = shift; bless {failing => 0, @_}, $c }
    sub audit_event      { return ($_[1]) }
    sub fail_count       { $_[0]->{failing} ? 1 : 0 }
    sub pass_count       { 0 }
    sub failing          { $_[0]->{failing} }
    sub passing          { !$_[0]->{failing} }
    sub set_process_info { }
    sub set_ipcm_info    { }
}

subtest 'no-wait-status modes - exit reflects auditor verdict' => sub {
    skip_all "fork required" unless $CAN_FORK;

    # Pipe-based collection where the collector cannot waitpid the watched
    # child (it is owned by another process). Without an exit code to mirror,
    # the collector falls back to the auditor's verdict.

    my $run_pipe_test = sub {
        my ($auditor_failing, $tag) = @_;

        pipe(my $out_r, my $out_w) or die "pipe: $!";
        pipe(my $err_r, my $err_w) or die "pipe: $!";

        my $child = fork();
        die "fork: $!" unless defined $child;
        if (!$child) {
            close($out_r);
            close($err_r);
            print $out_w "hello\n";
            close($out_w);
            close($err_w);
            exit(0);
        }
        close($out_w);
        close($err_w);

        my $collector = Test2::Harness2::Collector::Test->spawn(
            ipc_parent  => "test-peer", ipc_harness => "test-peer",
            ipcm_info => {},
            stdout    => $out_r,
            stderr    => $err_r,
            pid       => $child,
            auditor   => ['T2H2_Test_StubAuditor', failing => $auditor_failing],
            loggers   => [],
        );

        my $exit = $collector->wait();
        waitpid($child, 0);
        return $exit;
    };

    my $passing_exit = $run_pipe_test->(0, 'passing');
    is($passing_exit >> 8,  0, "auditor passing -> collector exits 0");
    is($passing_exit & 127, 0, "no signal in the wait-status");

    my $failing_exit = $run_pipe_test->(1, 'failing');
    is($failing_exit >> 8,  1, "auditor failing -> collector exits 1");
    is($failing_exit & 127, 0, "no signal in the wait-status");
};

subtest 'launch - env vars' => sub {
    my $output = "$tmpdir/a_env.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print $ENV{MY_TEST_VAR}, "\n"'],
        env_vars  => {MY_TEST_VAR => 'collector_test_value'},
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events = read_events($output);
    my ($out_ev) = find_events(\@events, stream => 'stdout');
    ok($out_ev, "found stdout event");
    like($out_ev->{facet_data}{from_stream}{details}, qr/collector_test_value/, "env var was passed");
};

subtest 'launch - env vars via spec name' => sub {
    my $output = "$tmpdir/a_env_spec.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print $ENV{SPEC_VAR}, "\n"'],
        env       => {SPEC_VAR => 'from_spec_name'},
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events = read_events($output);
    my ($out_ev) = find_events(\@events, stream => 'stdout');
    ok($out_ev, "found stdout event");
    like($out_ev->{facet_data}{from_stream}{details}, qr/from_spec_name/, "env var passed via spec name 'env'");
};

subtest 'launch - multi-line output' => sub {
    my $output = "$tmpdir/a_multi.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'for (1..5) { print "line $_\n" }'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    is(scalar @out_evs, 5, "got 5 stdout events");
};

subtest 'launch - string launch arg' => sub {
    my $output = "$tmpdir/a_string.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => 'echo hello_string',
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "got stdout event from string launch");
    like($out_evs[0]->{facet_data}{from_stream}{details}, qr/hello_string/, "string launch content correct");
};

# ===========================================================================
# Pipe-based collection tests (pipe handles + pid) -- require fork
# ===========================================================================

subtest 'pipes - pipe handles with pid' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/b_pipes.jsonl";

    pipe(my $out_r, my $out_w) or die "pipe: $!";
    pipe(my $err_r, my $err_w) or die "pipe: $!";

    my $child = fork();
    die "fork: $!" unless defined $child;

    if (!$child) {
        close($out_r);
        close($err_r);
        print $out_w "pipe stdout line 1\n";
        print $out_w "pipe stdout line 2\n";
        print $err_w "pipe stderr line 1\n";
        close($out_w);
        close($err_w);
        exit(7);
    }

    close($out_w);
    close($err_w);

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $out_r,
        stderr    => $err_r,
        pid       => $child,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();
    waitpid($child, 0);

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 2, "got at least 2 stdout events from pipes");

    my @err_evs = find_events(\@events, stream => 'stderr');
    ok(@err_evs >= 1, "got at least 1 stderr event from pipes");

    like($out_evs[0]->{facet_data}{from_stream}{details}, qr/pipe stdout line 1/, "first stdout line correct");
    like($err_evs[0]->{facet_data}{from_stream}{details}, qr/pipe stderr line 1/, "first stderr line correct");

    # Pipe-based collection does not capture exit code (did not start child)
    my @exit_evs = find_events(\@events, exit => 1);
    is(scalar @exit_evs, 0, "no exit event for externally-managed child");
};

subtest 'pipes - spec name mapping (stdout/stderr/pid)' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/b_specnames.jsonl";

    pipe(my $out_r, my $out_w) or die "pipe: $!";
    pipe(my $err_r, my $err_w) or die "pipe: $!";

    my $child = fork();
    die "fork: $!" unless defined $child;

    if (!$child) {
        close($out_r);
        close($err_r);
        print $out_w "spec name test\n";
        close($out_w);
        close($err_w);
        exit(0);
    }

    close($out_w);
    close($err_w);

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $out_r,
        stderr    => $err_r,
        pid       => $child,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();
    waitpid($child, 0);

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "spec name mapping works for stdout/stderr/pid");
    like($out_evs[0]->{facet_data}{from_stream}{details}, qr/spec name test/, "content correct");
};

subtest 'pipes - stdout pipe only (no stderr)' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/b_stdout_only.jsonl";

    pipe(my $out_r, my $out_w) or die "pipe: $!";

    my $child = fork();
    die "fork: $!" unless defined $child;

    if (!$child) {
        close($out_r);
        print $out_w "only stdout\n";
        close($out_w);
        exit(0);
    }

    close($out_w);

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $out_r,
        pid       => $child,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();
    waitpid($child, 0);

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "got stdout event with stdout-only pipe");
};

# ===========================================================================
# File-based collection tests (regular files, no Atomic::Pipe) -- all platforms
# ===========================================================================

subtest 'file - file handles' => sub {
    my $output = "$tmpdir/c_handles.jsonl";

    my $stdout_file = "$tmpdir/c_stdout.txt";
    my $stderr_file = "$tmpdir/c_stderr.txt";

    open(my $ofh, '>', $stdout_file) or die $!;
    print $ofh "file stdout line 1\n";
    print $ofh "file stdout line 2\n";
    close($ofh);

    open(my $efh, '>', $stderr_file) or die $!;
    print $efh "file stderr line 1\n";
    close($efh);

    open(my $out_fh, '<', $stdout_file) or die $!;
    open(my $err_fh, '<', $stderr_file) or die $!;

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        out_fh    => $out_fh,
        err_fh    => $err_fh,
        child_pid => undef,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    is(scalar @out_evs, 2, "got 2 stdout events from file handles");

    my @err_evs = find_events(\@events, stream => 'stderr');
    is(scalar @err_evs, 1, "got 1 stderr event from file handles");

    my @exit_evs = find_events(\@events, exit => 1);
    is(scalar @exit_evs, 0, "no exit event for file-based collection (no pid)");
};

subtest 'file - string paths' => sub {
    my $output = "$tmpdir/c_paths.jsonl";

    my $stdout_file = "$tmpdir/c_paths_stdout.txt";
    my $stderr_file = "$tmpdir/c_paths_stderr.txt";

    open(my $ofh, '>', $stdout_file) or die $!;
    print $ofh "path stdout line 1\n";
    print $ofh "path stdout line 2\n";
    print $ofh "path stdout line 3\n";
    close($ofh);

    open(my $efh, '>', $stderr_file) or die $!;
    print $efh "path stderr line 1\n";
    print $efh "path stderr line 2\n";
    close($efh);

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $stdout_file,
        stderr    => $stderr_file,
        pid       => undef,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    is(scalar @out_evs, 3, "got 3 stdout events from string paths");

    my @err_evs = find_events(\@events, stream => 'stderr');
    is(scalar @err_evs, 2, "got 2 stderr events from string paths");
};

subtest 'file - spec name mapping with paths' => sub {
    my $output = "$tmpdir/c_specnames.jsonl";

    my $stdout_file = "$tmpdir/c_spec_stdout.txt";
    my $stderr_file = "$tmpdir/c_spec_stderr.txt";

    open(my $ofh, '>', $stdout_file) or die $!;
    print $ofh "spec path test\n";
    close($ofh);

    open(my $efh, '>', $stderr_file) or die $!;
    print $efh "spec err test\n";
    close($efh);

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $stdout_file,
        stderr    => $stderr_file,
        pid       => undef,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "spec names work for file-based string paths");
};

# ===========================================================================
# Fifo-based collection tests -- require fork + mkfifo (Unix only)
# ===========================================================================

subtest 'fifo - fifo handles use Atomic::Pipe' => sub {
    skip_all "fork and mkfifo required" unless $CAN_FORK && $CAN_FIFO;

    my $fifo_out = "$tmpdir/fifo_stdout";
    my $fifo_err = "$tmpdir/fifo_stderr";

    POSIX::mkfifo($fifo_out, 0700) or die "mkfifo $fifo_out: $!";
    POSIX::mkfifo($fifo_err, 0700) or die "mkfifo $fifo_err: $!";

    my $output = "$tmpdir/c_fifo.jsonl";

    my $writer = fork();
    die "fork: $!" unless defined $writer;

    if (!$writer) {
        open(my $out_w, '>', $fifo_out) or die "open fifo_out: $!";
        open(my $err_w, '>', $fifo_err) or die "open fifo_err: $!";

        print $out_w "fifo stdout line 1\n";
        print $out_w "fifo stdout line 2\n";
        print $err_w "fifo stderr line 1\n";

        close($out_w);
        close($err_w);
        exit(0);
    }

    open(my $out_r, '<', $fifo_out) or die "open fifo_out reader: $!";
    open(my $err_r, '<', $fifo_err) or die "open fifo_err reader: $!";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $out_r,
        stderr    => $err_r,
        pid       => undef,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();
    waitpid($writer, 0);

    my @events = read_events($output);

    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 2, "got at least 2 stdout events from fifo");

    my @err_evs = find_events(\@events, stream => 'stderr');
    ok(@err_evs >= 1, "got at least 1 stderr event from fifo");

    like($out_evs[0]->{facet_data}{from_stream}{details}, qr/fifo stdout line 1/, "fifo stdout content correct");
    like($err_evs[0]->{facet_data}{from_stream}{details}, qr/fifo stderr line 1/, "fifo stderr content correct");

    unlink($fifo_out);
    unlink($fifo_err);
};

subtest 'fifo - fifo string paths' => sub {
    skip_all "fork and mkfifo required" unless $CAN_FORK && $CAN_FIFO;

    my $fifo_out = "$tmpdir/fifo_path_stdout";
    my $fifo_err = "$tmpdir/fifo_path_stderr";

    POSIX::mkfifo($fifo_out, 0700) or die "mkfifo $fifo_out: $!";
    POSIX::mkfifo($fifo_err, 0700) or die "mkfifo $fifo_err: $!";

    my $output = "$tmpdir/c_fifo_paths.jsonl";

    my $writer = fork();
    die "fork: $!" unless defined $writer;

    if (!$writer) {
        open(my $out_w, '>', $fifo_out) or die "open: $!";
        open(my $err_w, '>', $fifo_err) or die "open: $!";
        print $out_w "fifo path out\n";
        print $err_w "fifo path err\n";
        close($out_w);
        close($err_w);
        exit(0);
    }

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $fifo_out,
        stderr    => $fifo_err,
        pid       => undef,
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();
    waitpid($writer, 0);

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "got stdout event from fifo string path");

    my @err_evs = find_events(\@events, stream => 'stderr');
    ok(@err_evs >= 1, "got stderr event from fifo string path");

    unlink($fifo_out);
    unlink($fifo_err);
};

# ===========================================================================
# Child termination (all platforms)
# ===========================================================================

subtest 'child killed when parent_pids disappear' => sub {
    # Launch a long-running child, pass a parent_pid that is already gone
    # (use a PID we know doesn't exist).  The collector should detect the
    # dead parent, kill the child, and exit cleanly.
    my $output = "$tmpdir/kill_parent.jsonl";

    # Pick a PID that almost certainly does not exist
    my $fake_parent = 2_000_000_000;

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent    => "test-peer", ipc_harness => "test-peer",
        ipcm_info   => {},
        launch      => ['perl', '-e', 'sleep 300'],
        loggers     => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
        parent_pids => [$fake_parent],
    );

    my $exit = $collector->wait();

    # Collector should have exited (not hung for 300 seconds)
    ok(defined $exit, "collector exited after detecting dead parent pid");

    # The output file should exist (log was written before exit)
    ok(-f $output, "output log was written");
};

subtest 'child killed on signal' => sub {
    skip_all "fork required for signal test" unless $CAN_FORK;

    my $output = "$tmpdir/kill_signal.jsonl";

    # Use a child that prints something first so the collector has time
    # to enter its loop and open the output file before we signal it.
    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print "started\n"; sleep 300'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $cpid = $collector->pid;
    ok($cpid, "collector process is running");

    # Wait until the output file appears (collector has entered the loop)
    my $deadline = time + 5;
    while (!-f $output && time < $deadline) {
        sleep(0.1);
    }

    # Send TERM to the collector process
    kill('TERM', $cpid);

    my $exit = $collector->wait();
    ok(defined $exit, "collector exited after TERM signal");
    ok(-f $output,    "output log was written before exit");
};

subtest 'graceful SIGTERM: collector exits promptly and child is reaped' => sub {
    skip_all "fork required for signal test" unless $CAN_FORK;

    my $output = "$tmpdir/graceful_term.jsonl";

    # Child sleeps long enough that it would not exit on its own.
    # It prints a line first so the collector enters its loop before we
    # signal it.
    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print "ready\n"; sleep 60'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $cpid = $collector->pid;
    ok($cpid, "collector process is running");

    # Grab the test child's PID from /proc or via a small helper fork so we
    # can verify it is dead after the collector exits.  We learn it from the
    # exit event that the collector writes -- but that is only available after
    # the fact.  Instead, we ask the collector's pid to find its children: on
    # Linux /proc/$cpid/task/*/children works; elsewhere we rely on the
    # collector having only one child.  Since we cannot reliably enumerate
    # children portably, we take the simple approach: record the PID range
    # and check via kill(0) after the fact.

    # Wait for the output file to appear so the collector has opened the log
    # and is in the main collection loop.
    my $deadline = time + 5;
    while (!-f $output && time < $deadline) {
        sleep(0.05);
    }
    ok(-f $output, "output file exists: collector entered main loop");

    # Send SIGTERM to the collector.
    kill('TERM', $cpid);

    # Collector must exit within a few seconds (not hang for the child's
    # full sleep(60) duration).
    my $start    = time;
    my $exit_val = $collector->wait();
    my $elapsed  = time - $start;

    ok(defined $exit_val, "collector exited after SIGTERM");
    ok($elapsed < 10,     "collector exited promptly (within 10s, took ${elapsed}s)");

    # Confirm the collector process is gone.
    my $collector_dead = !kill(0, $cpid);
    ok($collector_dead, "collector process is dead after wait()");

    # Read the exit event to find the child PID and confirm the child is
    # also dead.  The collector writes a harness_process_exit facet which
    # includes the wait-status but not the PID directly.  We instead parse
    # /proc (Linux) or rely on the kill-0 check against the child PID we
    # embedded in the log output.
    #
    # Simplest reliable approach: scan /proc for any child of the (now-dead)
    # collector.  Since the collector is gone, its children were either reaped
    # by us or became orphans adopted by init.  Either way they should be dead
    # or about to be -- check /proc if available, otherwise skip the child-dead
    # assertion.
    if (-d '/proc') {
        # Collect all PIDs that list $cpid as their parent.
        # /proc/<pid>/stat format: pid (comm) state ppid ...
        # comm can contain spaces, so we strip the (comm) field before splitting.
        my @orphans;
        opendir(my $dh, '/proc') or die "opendir /proc: $!";
        for my $entry (readdir($dh)) {
            next unless $entry =~ /^\d+$/;
            my $stat = "/proc/$entry/stat";
            next unless -r $stat;
            eval {
                open(my $fh, '<', $stat) or return;
                my $line = <$fh>;
                close $fh;
                # Strip the (comm) field which may contain spaces/parens, then split
                $line =~ s/^\d+\s+\(.*?\)\s+//;
                my @f = split(' ', $line);
                # After stripping, f[0]=state f[1]=ppid
                push @orphans => $entry if defined($f[1]) && $f[1] == $cpid;
            };
        }
        closedir($dh);
        is(scalar @orphans, 0, "no child processes remain under the (dead) collector pid");
    }
    else {
        pass("skipping /proc child check (not on Linux)");
    }
};

subtest 'ignore-class signals do not kill the collector' => sub {
    skip_all "fork required for signal test" unless $CAN_FORK;

    my $output = "$tmpdir/ignore_sigs.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print "ready\n"; sleep 60'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    my $cpid = $collector->pid;
    ok($cpid, "collector process is running");

    # Wait for the collector to be in its main loop.
    my $deadline = time + 5;
    while (!-f $output && time < $deadline) {
        sleep(0.05);
    }
    ok(-f $output, "output file exists: collector entered main loop");

    # Send SIGUSR1 -- collector must ignore it and keep running.
    kill('USR1', $cpid);
    sleep(0.2);

    my $still_alive = kill(0, $cpid);
    ok($still_alive, "collector is still alive after SIGUSR1");

    # Clean up: send TERM so the collector exits before the test suite moves on.
    kill('TERM', $cpid);
    $collector->wait();

    ok(!kill(0, $cpid), "collector exited after cleanup SIGTERM");
};

# ===========================================================================
# Exception resilience (all platforms)
# ===========================================================================

{
    # A parser that explodes after the first event to test exception handling
    package Test2::Harness2::Collector::Parser::_Exploding;
    use parent 'Test2::Harness2::Collector::Parser::IOParser';

    my $call_count = 0;

    sub parse_io {
        my $self = shift;
        $call_count++;
        die "Intentional kaboom on call $call_count" if $call_count > 1;
        return $self->SUPER::parse_io(@_);
    }

    sub _reset { $call_count = 0 }
}

subtest 'exception in run loop is logged as error event' => sub {
    Test2::Harness2::Collector::Parser::_Exploding->_reset();

    my $output = "$tmpdir/exception.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', 'print "line1\n"; print "line2\n"'],
        parser    => Test2::Harness2::Collector::Parser::_Exploding->new(ipcm_info => {}),
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
    );

    $collector->wait();

    my @events = read_events($output);

    my @error_evs = grep { exists $_->{facet_data}{errors} } @events;
    ok(@error_evs >= 1, "got at least 1 error event from exception");
    like(
        $error_evs[0]->{facet_data}{errors}[0]{details},
        qr/Intentional kaboom/,
        "error event contains the exception message"
    );
    is($error_evs[0]->{facet_data}{errors}[0]{fail}, 1, "error event marked as failure");
};

# ===========================================================================
# Construction validation (all platforms)
# ===========================================================================

subtest 'construction validation' => sub {
    like(
        dies { Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", ipcm_info => {}) },
        qr/Must specify either/,
        "dies without launch or stdout/stderr"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                launch    => ['echo'],
                stdout    => \*STDIN,
            )
        },
        qr/not both/,
        "dies with both launch and stdout"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                launch    => ['echo'],
                loggers   => 'not-an-arrayref',
            )
        },
        qr/loggers.*must be an arrayref/,
        "dies when loggers is not an arrayref"
    );

    # Logger-paths refactor: output_file is now derived from the
    # collector's identity attributes, so Logger::JSONL no longer
    # requires output_file up front at construction time.
    ok(
        Test2::Harness2::Collector::Logger::JSONL->new(ipcm_info => {}),
        "JSONL logger constructs without an explicit output_file"
    );

    # The real invariant: output_files() -- not new() -- croaks when
    # neither output_file nor logdir is available, because the role's
    # output_file_basename needs logdir to derive a path.
    like(
        dies { Test2::Harness2::Collector::Logger::JSONL->new(ipcm_info => {})->output_files },
        qr/logdir/,
        "JSONL logger croaks at output_files when neither output_file nor logdir is available"
    );
};

subtest 'spec validation - bad shapes are rejected at init' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                stdout    => $devnull,
                loggers   => [{bogus => 1}],
            )
        },
        qr/Invalid logger specification/,
        "hashref logger spec rejected"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                stdout    => $devnull,
                loggers   => [[]],
            )
        },
        qr/Logger arrayref must begin with a class name/,
        "empty arrayref logger spec rejected"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                stdout    => $devnull,
                auditor   => {bogus => 1},
            )
        },
        qr/Invalid auditor specification/,
        "hashref auditor spec rejected"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                stdout    => $devnull,
                auditor   => 'Test2::Harness2::Util',    # exists but doesn't DOES role
            )
        },
        qr/does not implement Test2::Harness2::Role::Auditor/,
        "auditor class missing role rejected at validate time"
    );

    like(
        dies {
            Test2::Harness2::Collector::Test->new(
                ipc_parent  => "test-peer", ipc_harness => "test-peer",
                ipcm_info => {},
                stdout    => $devnull,
                loggers   => ['Test2::Harness2::Util'],
            )
        },
        qr/does not implement Test2::Harness2::Role::Collector::Logger/,
        "logger class missing role rejected at validate time"
    );
};

subtest 'spec instantiation is deferred to the collector child' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    # Sentinel class that records every constructor call. If init() instantiates
    # it, the count goes up in the parent. We expect the count to be zero in
    # the parent right after construction.
    package T2H2_Test_Sentinel_Logger;
    our $CONSTRUCTED = 0;
    sub new              { $CONSTRUCTED++; bless {}, shift }
    sub depends_on       { () }
    sub log_events       { 0 }
    sub log_event        { }
    sub startup          { }
    sub shutdown         { }
    sub failing          { }
    sub set_process_info { }
    sub set_ipcm_info    { }
    sub update_style     { 'append' }
    sub log_reader       { undef }
    sub ready            { 0 }
    sub fetch_events     { () }
    sub fetch_state      { undef }
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Logger';

    package main;

    package T2H2_Test_Sentinel_Auditor;
    our $CONSTRUCTED = 0;
    sub new              { $CONSTRUCTED++; bless {}, shift }
    sub audit_event      { return ($_[1]) }
    sub fail_count       { 0 }
    sub pass_count       { 0 }
    sub failing          { 0 }
    sub passing          { 1 }
    sub set_process_info { }
    sub set_ipcm_info    { }
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Auditor';

    package main;

    $T2H2_Test_Sentinel_Logger::CONSTRUCTED  = 0;
    $T2H2_Test_Sentinel_Auditor::CONSTRUCTED = 0;

    my $c = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $devnull,
        loggers   => ['T2H2_Test_Sentinel_Logger'],
        auditor   => 'T2H2_Test_Sentinel_Auditor',
    );

    is($T2H2_Test_Sentinel_Logger::CONSTRUCTED,  0, "logger constructor not called in init()");
    is($T2H2_Test_Sentinel_Auditor::CONSTRUCTED, 0, "auditor constructor not called in init()");

    # Loggers/auditor accessors return the original specs (not instances).
    is($c->loggers, ['T2H2_Test_Sentinel_Logger'], "loggers attr holds spec");
    is($c->auditor, 'T2H2_Test_Sentinel_Auditor',  "auditor attr holds spec");
};

subtest 'blessed instances pass through unchanged and survive validation' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    package T2H2_Test_Blessed_Logger;
    sub new              { bless {}, shift }
    sub depends_on       { () }
    sub log_events       { 0 }
    sub log_event        { }
    sub startup          { }
    sub shutdown         { }
    sub failing          { }
    sub set_process_info { }
    sub set_ipcm_info    { }
    sub update_style     { 'append' }
    sub log_reader       { undef }
    sub ready            { 0 }
    sub fetch_events     { () }
    sub fetch_state      { undef }
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Logger';

    package main;

    my $logger = T2H2_Test_Blessed_Logger->new();
    my $c      = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        stdout    => $devnull,
        loggers   => [$logger],
    );

    is($c->loggers->[0], exact_ref($logger), "blessed logger spec preserved");
};

# ===========================================================================
# Interpose tests (fork+capture current process) -- require fork
# ===========================================================================

subtest 'interpose - captures output and exit code' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/d_interpose.jsonl";

    # We must fork first because interpose() causes the child to resume
    # execution and the parent to exit() after collecting.  Running
    # interpose() directly inside the test process would kill the harness.
    my $outer = fork();
    die "fork: $!" unless defined $outer;

    if (!$outer) {
        Test2::Harness2::Collector::Test->interpose(
            ipc_parent  => "test-peer", ipc_harness => "test-peer",
            ipcm_info => {},
            loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
        );

        # Only the child (original execution path) reaches here
        print "interpose stdout\n";
        print STDERR "interpose stderr\n";
        exit(0);
    }

    # Test process waits for the collector (the outer fork became the
    # collector parent; it exits when the inner child finishes).
    waitpid($outer, 0);
    is($?, 0, "collector exited cleanly");

    my @events = read_events($output);

    my @out_evs = find_events(\@events, stream => 'stdout');
    ok(@out_evs >= 1, "got stdout event from interposed child");
    like($out_evs[0]->{facet_data}{from_stream}{details}, qr/interpose stdout/, "stdout content correct");

    my @err_evs = find_events(\@events, stream => 'stderr');
    ok(@err_evs >= 1, "got stderr event from interposed child");
    like($err_evs[0]->{facet_data}{from_stream}{details}, qr/interpose stderr/, "stderr content correct");

    my ($exit_ev) = find_events(\@events, exit => 1);
    ok($exit_ev, "found exit event");
    is($exit_ev->{facet_data}{harness_process_exit}{err}, 0, "exit status 0");
};

subtest 'interpose - captures non-zero exit' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/d_interpose_exit.jsonl";

    my $outer = fork();
    die "fork: $!" unless defined $outer;

    if (!$outer) {
        Test2::Harness2::Collector::Test->interpose(
            ipc_parent  => "test-peer", ipc_harness => "test-peer",
            ipcm_info => {},
            loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
        );
        exit(17);
    }

    waitpid($outer, 0);
    is($? >> 8, 17, "collector mirrored child's non-zero exit");

    my @events = read_events($output);
    my ($exit_ev) = find_events(\@events, exit => 1);
    ok($exit_ev, "found exit event");
    is($exit_ev->{facet_data}{harness_process_exit}{err}, 17, "exit code 17 captured");
};

subtest 'interpose - jump_to unwinds to setjump with payload' => sub {
    skip_all "fork required" unless $CAN_FORK;

    require Long::Jump;
    my $output = "$tmpdir/d_interpose_jump.jsonl";

    my $outer = fork();
    die "fork: $!" unless defined $outer;

    if (!$outer) {
        my $ret = Long::Jump::setjump(
            'interpose_pt',
            sub {
                Test2::Harness2::Collector::Test->interpose(
                    ipc_parent     => "test-peer", ipc_harness => "test-peer",
                    ipcm_info    => {},
                    loggers      => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
                    jump_to      => 'interpose_pt',
                    jump_payload => sub { print "from payload\n"; 42 },
                );
                # The child never reaches here because the longjump happens inside
                # interpose. The parent never reaches here either because it turns
                # into the collector and exits.
                POSIX::_exit(100);
            }
        );

        my ($payload) = @$ret;
        die "setjump did not get a payload" unless ref($payload) eq 'CODE';
        my $from_payload = $payload->();
        print "payload returned: $from_payload\n";
        exit(0);
    }

    waitpid($outer, 0);
    is($?, 0, "collector exited cleanly on the jump path");

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    my @lines   = map { $_->{facet_data}{from_stream}{details} } @out_evs;
    ok((grep { /from payload/ } @lines),         "payload output captured");
    ok((grep { /payload returned: 42/ } @lines), "post-payload output captured");
};

subtest 'interpose - jump_to croaks without an active setjump' => sub {
    my $err;
    {
        local $@;
        eval {
            Test2::Harness2::Collector::Test->interpose(
                ipc_parent     => "test-peer", ipc_harness => "test-peer",
                ipcm_info    => {},
                jump_to      => 'not_set',
                jump_payload => sub { },
            );
            1;
        };
        $err = $@;
    }
    like($err, qr/No active setjump/, 'interpose croaks when setjump is missing');
};

subtest 'interpose - jump_payload without jump_to is an error' => sub {
    my $err;
    {
        local $@;
        eval {
            Test2::Harness2::Collector::Test->interpose(
                ipc_parent     => "test-peer", ipc_harness => "test-peer",
                ipcm_info    => {},
                jump_payload => sub { },
            );
            1;
        };
        $err = $@;
    }
    like($err, qr/jump_payload.*requires.*jump_to/i, 'payload without jump_to is rejected');
};

subtest 'interpose - multi-line output' => sub {
    skip_all "fork required" unless $CAN_FORK;

    my $output = "$tmpdir/d_interpose_multi.jsonl";

    my $outer = fork();
    die "fork: $!" unless defined $outer;

    if (!$outer) {
        Test2::Harness2::Collector::Test->interpose(
            ipc_parent  => "test-peer", ipc_harness => "test-peer",
            ipcm_info => {},
            loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $output]],
        );
        for (1 .. 3) { print "line $_\n" }
        exit(0);
    }

    waitpid($outer, 0);

    my @events  = read_events($output);
    my @out_evs = find_events(\@events, stream => 'stdout');
    is(scalar @out_evs, 3, "got 3 stdout events from interposed child");
};

subtest 'new_pgroup attribute defaults to 0' => sub {
    my $c = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', '1'],
    );
    is($c->new_pgroup, 0, 'defaults to 0');
};

subtest 'new_pgroup attribute can be set to 1' => sub {
    my $c = Test2::Harness2::Collector::Test->new(
        ipc_parent   => "test-peer", ipc_harness => "test-peer",
        ipcm_info  => {},
        launch     => ['perl', '-e', '1'],
        new_pgroup => 1,
    );
    is($c->new_pgroup, 1, 'set to 1');
};

subtest 'new_pgroup=1 puts launched child in its own pgroup (Unix)' => sub {
    skip_all 'Unix-only' if $^O eq 'MSWin32';

    require File::Temp;
    my $tmp     = File::Temp->new(SUFFIX => '.jsonl');
    my $tmpfile = $tmp->filename;
    $tmp->close;

    my $handle = Test2::Harness2::Collector::Test->spawn(
        ipc_parent   => "test-peer", ipc_harness => "test-peer",
        ipcm_info  => {},
        launch     => [$^X, '-e', 'print STDOUT "pgid=", getpgrp(), " pid=", $$, "\n"'],
        new_pgroup => 1,
        loggers    => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $tmpfile]],
    );

    my $exit = $handle->wait;
    is($exit, 0, 'child exited cleanly');

    my @events = read_events($tmpfile);
    my ($out_ev) = find_events(\@events, stream => 'stdout');
    ok($out_ev, 'found stdout event') or diag encode_json(\@events);

    my $details = $out_ev->{facet_data}{from_stream}{details} // '';
    my ($pgid)  = $details =~ /pgid=(\d+)/;
    my ($pid)   = $details =~ /pid=(\d+)/;
    ok($pid && $pgid, "captured pid=$pid and pgid=$pgid from log") or diag "details: $details";
    is($pgid, $pid, 'child is own pgroup leader (pgid == pid)');
};

subtest 'new_pgroup=0 leaves child in parent pgroup (Unix)' => sub {
    skip_all 'Unix-only' if $^O eq 'MSWin32';

    require File::Temp;
    my $tmp     = File::Temp->new(SUFFIX => '.jsonl');
    my $tmpfile = $tmp->filename;
    $tmp->close;

    my $handle = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => [$^X, '-e', 'print STDOUT "pgid=", getpgrp(), "\n"'],
        loggers   => [['Test2::Harness2::Collector::Logger::JSONL', output_file => $tmpfile]],
    );
    $handle->wait;

    my @events = read_events($tmpfile);
    my ($out_ev) = find_events(\@events, stream => 'stdout');
    ok($out_ev, 'found stdout event') or diag encode_json(\@events);

    my $details = $out_ev->{facet_data}{from_stream}{details} // '';
    my ($pgid) = $details =~ /pgid=(\d+)/;
    ok(defined($pgid), "captured pgid=$pgid from log") or diag "details: $details";
    is($pgid, getpgrp(), "child pgid matches parent's own pgroup");
};

subtest 'new_pgroup throws on Windows without Win32::Job' => sub {
    my $collector = Test2::Harness2::Collector::Test->new(
        ipc_parent   => "test-peer", ipc_harness => "test-peer",
        ipcm_info  => {},
        stdout     => \*STDOUT,
        new_pgroup => 1,
    );

    # Call the check directly to verify it croaks with the expected message
    my $ok  = eval { $collector->_check_new_pgroup_supported_on_win32(); 1 };
    my $err = $@;

    ok(!$ok, 'check raises exception');
    like($err, qr/Win32::Job/, 'error names the required module');
    like($err, qr/new_pgroup/, 'error mentions the feature');
};

subtest 'Handle requires pid' => sub {
    like(
        dies { Test2::Harness2::Collector::Handle->new() },
        qr/pid.*required/,
        'croaks without pid',
    );
};

subtest 'Handle->is_done - non-blocking completion check' => sub {
    skip_all "fork required" unless $CAN_FORK;

    # Handle for a still-running child returns false, then true after exit.
    my $child = fork // die "fork: $!";
    if (!$child) { sleep 30; POSIX::_exit(0); }

    my $handle = Test2::Harness2::Collector::Handle->new(pid => $child);
    ok(!$handle->is_done, 'is_done returns false while child is alive');

    kill 'TERM', $child;
    # Wait for termination, then confirm is_done returns true.
    waitpid($child, 0);

    # Re-wrap the same pid after it has been reaped to confirm a
    # freshly-reaped pid comes back as done.
    my $child2 = fork // die "fork: $!";
    if (!$child2) { POSIX::_exit(0); }

    my $h2 = Test2::Harness2::Collector::Handle->new(pid => $child2);
    # Give the child a moment to exit.
    sleep(0.05);
    ok($h2->is_done,           'is_done returns true after child exits');
    ok(defined $h2->exit_code, 'exit_code recorded on reap');
};

# ===========================================================================
# $SIG{__WARN__} handler routes collector-process warnings through loggers
# ===========================================================================

{

    # A logger that emits a warn() during shutdown so we can exercise the
    # $SIG{__WARN__} handler that _run_collector installs.  shutdown() fires
    # after the handler is in place and after the child has been collected, so
    # any warnings produced there must appear in the JSONL log as WARNING info
    # events in addition to going to STDERR.
    package T2H2_Test_WarnOnShutdown_Logger;
    use parent 'Test2::Harness2::Collector::Logger::JSONL';

    sub shutdown {
        my $self = shift;
        warn "collector-process warning from shutdown\n";
        $self->SUPER::shutdown(@_);
    }
}

subtest 'collector-process warnings are routed through loggers' => sub {
    my $output = "$tmpdir/warn_handler.jsonl";

    my $collector = Test2::Harness2::Collector::Test->spawn(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        ipcm_info => {},
        launch    => ['perl', '-e', '1'],
        loggers   => [T2H2_Test_WarnOnShutdown_Logger->new(ipcm_info => {}, output_file => $output)],
    );

    my $exit = $collector->wait();
    is($exit, 0, "collector exited cleanly");

    my @events = read_events($output);
    ok(@events >= 1, "got at least one event");

    my @warn_evs = grep {
        my $info = $_->{facet_data}{info};
        $info && grep { ($_->{tag} // '') eq 'WARNING' } @$info;
    } @events;

    ok(@warn_evs >= 1, "found at least one WARNING info event in the log");
    like(
        $warn_evs[0]->{facet_data}{info}[0]{details},
        qr/collector-process warning from shutdown/,
        "WARNING event contains the warning text",
    );
    is($warn_evs[0]->{facet_data}{info}[0]{debug}, 1, "WARNING event is marked debug");
};

use Test2::Harness2::Collector::Handle;

# ===========================================================================
# Process-info attributes (run_id / job_id / job_try / ipcm_info)
# ===========================================================================

subtest 'run_id defaults to undef' => sub {
    my $c = Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", ipcm_info => {}, launch => ['perl', '-e', '1']);
    ok(!defined $c->run_id, 'run_id defaults to undef');
};

subtest 'job_id auto-generated as UUID' => sub {
    my $c = Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", ipcm_info => {}, launch => ['perl', '-e', '1']);
    like($c->job_id, qr/^[0-9A-F-]{36}$/i, 'job_id auto-generated as UUID');
};

subtest 'job_try defaults to 0' => sub {
    my $c = Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", ipcm_info => {}, launch => ['perl', '-e', '1']);
    is($c->job_try, 0, 'job_try defaults to 0');
};

subtest 'ipcm_info stored when provided' => sub {
    my $ii = {host => 'localhost'};
    my $c  = Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", ipcm_info => $ii, launch => ['perl', '-e', '1']);
    is($c->ipcm_info, $ii, 'ipcm_info stored on the collector');
};

subtest 'explicit run_id/job_id/job_try/ipcm_info accepted at construction' => sub {
    my $ii = {host => 'localhost'};
    my $c  = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        launch    => ['perl', '-e', '1'],
        run_id    => 'my-run',
        job_id    => 'my-job',
        job_try   => 2,
        ipcm_info => $ii,
    );
    is($c->run_id,    'my-run', 'run_id stored');
    is($c->job_id,    'my-job', 'job_id stored');
    is($c->job_try,   2,        'job_try stored');
    is($c->ipcm_info, $ii,      'ipcm_info stored');
};

subtest 'blessed auditor receives set_process_info and set_ipcm_info at instantiation' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    our @T2H2_RecordingAuditor_PI;
    our @T2H2_RecordingAuditor_IPCM;
    @T2H2_RecordingAuditor_PI   = ();
    @T2H2_RecordingAuditor_IPCM = ();

    package T2H2_Test_RecordingAuditor;
    sub new              { bless {}, shift }
    sub audit_event      { return ($_[1]) }
    sub fail_count       { 0 }
    sub pass_count       { 0 }
    sub failing          { 0 }
    sub passing          { 1 }
    sub set_process_info { push @main::T2H2_RecordingAuditor_PI   => {@_[1 .. $#_]}; return }
    sub set_ipcm_info    { push @main::T2H2_RecordingAuditor_IPCM => $_[1];          return }
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Auditor';

    package main;

    my $auditor = T2H2_Test_RecordingAuditor->new();
    my $ii      = {fake => 1};

    my $c = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        stdout    => $devnull,
        run_id    => 'RRR',
        job_id    => 'JJJ',
        job_try   => 7,
        ipcm_info => $ii,
        auditor   => $auditor,
    );

    # Trigger instantiation (normally happens in child, but we can call directly)
    $c->_instantiate_auditor();

    is(scalar @T2H2_RecordingAuditor_PI,      1,     'set_process_info called once on blessed auditor');
    is($T2H2_RecordingAuditor_PI[0]{run_id},  'RRR', 'run_id passed to set_process_info');
    is($T2H2_RecordingAuditor_PI[0]{job_id},  'JJJ', 'job_id passed to set_process_info');
    is($T2H2_RecordingAuditor_PI[0]{job_try}, 7,     'job_try passed to set_process_info');

    is(scalar @T2H2_RecordingAuditor_IPCM, 1,   'set_ipcm_info called once on blessed auditor');
    is($T2H2_RecordingAuditor_IPCM[0],     $ii, 'ipcm_info value passed to set_ipcm_info');
};

subtest 'blessed logger receives set_process_info and set_ipcm_info at instantiation' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    our @T2H2_RecordingLogger_PI;
    our @T2H2_RecordingLogger_IPCM;
    @T2H2_RecordingLogger_PI   = ();
    @T2H2_RecordingLogger_IPCM = ();

    package T2H2_Test_RecordingLogger;
    sub new                { bless {}, shift }
    sub depends_on         { () }
    sub log_events         { 0 }
    sub log_event          { }
    sub startup            { }
    sub shutdown           { }
    sub failing            { }
    sub applicable         { 1 }
    sub set_process_info   { push @main::T2H2_RecordingLogger_PI   => {@_[1 .. $#_]}; return }
    sub set_ipcm_info      { push @main::T2H2_RecordingLogger_IPCM => $_[1];          return }
    sub set_auditor        { }
    sub set_loggers_lookup { }
    sub update_style       { 'append' }
    sub log_reader         { undef }
    sub ready              { 0 }
    sub fetch_events       { () }
    sub fetch_state        { undef }
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Collector::Logger';

    package main;

    my $logger = T2H2_Test_RecordingLogger->new();
    my $ii     = {fake => 2};

    my $c = Test2::Harness2::Collector::Test->new(
        ipc_parent  => "test-peer", ipc_harness => "test-peer",
        stdout    => $devnull,
        run_id    => 'R2',
        job_id    => 'J2',
        job_try   => 1,
        ipcm_info => $ii,
        loggers   => [$logger],
    );

    $c->_instantiate_loggers();

    is(scalar @T2H2_RecordingLogger_PI,      1,    'set_process_info called once on blessed logger');
    is($T2H2_RecordingLogger_PI[0]{run_id},  'R2', 'run_id passed');
    is($T2H2_RecordingLogger_PI[0]{job_id},  'J2', 'job_id passed');
    is($T2H2_RecordingLogger_PI[0]{job_try}, 1,    'job_try passed');

    is(scalar @T2H2_RecordingLogger_IPCM, 1,   'set_ipcm_info called once on blessed logger');
    is($T2H2_RecordingLogger_IPCM[0],     $ii, 'ipcm_info value passed');
};

# ===========================================================================
# ipcm_info required at construction
# ===========================================================================

subtest 'ipcm_info is required at construction - Collector' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Test->new(ipc_parent => "test-peer", ipc_harness => "test-peer", launch => ['perl', '-e', '1']); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

subtest 'ipcm_info is required at construction - Collector::Logger::JSONL' => sub {
    my $ok  = eval { Test2::Harness2::Collector::Logger::JSONL->new(output_file => '/dev/null'); 1 };
    my $err = $@;
    ok(!$ok, 'croaks without ipcm_info');
    like($err, qr/ipcm_info/, 'error mentions ipcm_info');
};

# ===========================================================================
# Logger metadata + collector_artifacts IPC send
# ===========================================================================

subtest '_send_logger_metadata groups metadata and registers under the collector-bus id' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    my @connect_args;
    my @sent;
    no warnings 'once', 'redefine';
    local *IPC::Manager::connect = sub {
        my (undef, @rest) = @_;
        push @connect_args => \@rest;
        return bless {sent => \@sent}, 'T2H2_FakeClient_LMeta';
    };
    *T2H2_FakeClient_LMeta::peer_active = sub { 1 };
    *T2H2_FakeClient_LMeta::send_message = sub {
        my ($self, $to, $payload) = @_;
        push @{$self->{sent}} => {to => $to, payload => $payload};
        return;
    };
    *T2H2_FakeClient_LMeta::try_send_message  = sub { my $self = shift; $self->send_message(@_); 1 };
    *T2H2_FakeClient_LMeta::set_send_blocking = sub { return };

    # Two JSONL loggers at different paths to show class keys map to arrayrefs.
    my $jsonl_a = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {}, output_file => '/tmp/a.jsonl',
    );
    my $jsonl_b = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {}, output_file => '/tmp/b.jsonl',
    );

    # Service-collector bus_id identifies by ipc_parent (the
    # interposed service's bus name). Use the Service subclass
    # here so this test still exercises that code path now that
    # _build_collector_bus_id lives on the subclasses.
    require Test2::Harness2::Collector::Service;
    my $c = Test2::Harness2::Collector::Service->new(
        stdout    => $devnull,
        ipcm_info => {fake => 1},
        ipc_parent  => 'harness', ipc_harness => 'harness',
        run_id    => 'R1',
        job_id    => 'J1',
        job_try   => 0,
        loggers   => [$jsonl_a, $jsonl_b],
    );

    $c->_instantiate_loggers();
    $c->_send_logger_metadata;

    is(scalar @connect_args,   1,                   'exactly one IPC client connected');
    is(
        $connect_args[0][0], 'collector:harness',
        'Service collector bus_id derives from ipc_parent',
    );

    is(scalar @sent,               1,               'exactly one send_message call');
    is($sent[0]{to},               'harness',       'sent to the configured peer');
    is($sent[0]{payload}{kind},    'collector_artifacts', 'collector_artifacts message kind');
    is($sent[0]{payload}{run_id},  'R1',            'carries run_id');
    is($sent[0]{payload}{job_id},  'J1',            'carries job_id');
    is($sent[0]{payload}{job_try}, 0,               'carries job_try');

    my $jsonl_class = 'Test2::Harness2::Collector::Logger::JSONL';
    my $meta        = $sent[0]{payload}{loggers}{$jsonl_class};
    is(ref($meta),    'ARRAY',                        'class key maps to an arrayref');
    is(scalar @$meta, 2,                              'both JSONL logger instances represented');
    is($meta->[0],    {jsonl_file => '/tmp/a.jsonl'}, 'first JSONL metadata');
    is($meta->[1],    {jsonl_file => '/tmp/b.jsonl'}, 'second JSONL metadata');
};

subtest '_send_logger_metadata omits loggers whose metadata is undef' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    my @sent;
    no warnings 'once', 'redefine';
    local *IPC::Manager::connect = sub {
        return bless {sent => \@sent}, 'T2H2_FakeClient_Omit';
    };
    *T2H2_FakeClient_Omit::peer_active  = sub { 1 };
    *T2H2_FakeClient_Omit::send_message = sub {
        my ($self, $to, $payload) = @_;
        push @{$self->{sent}} => $payload;
        return;
    };
    *T2H2_FakeClient_Omit::try_send_message  = sub { my $self = shift; $self->send_message(@_); 1 };
    *T2H2_FakeClient_Omit::set_send_blocking = sub { return };

    # JSONL produces metadata; the bare role default is undef.
    my $jsonl = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {}, output_file => '/tmp/one.jsonl',
    );
    my $silent = T2H2_SilentLogger->new;

    my $c = Test2::Harness2::Collector::Test->new(
        stdout    => $devnull,
        ipcm_info => {fake => 1},
        ipc_parent  => 'harness', ipc_harness => 'harness',
        loggers   => [$jsonl, $silent],
    );
    $c->_instantiate_loggers();
    $c->_send_logger_metadata;

    is(scalar @sent, 1, 'one message sent');
    my $loggers = $sent[0]{loggers};

    my $jsonl_class  = 'Test2::Harness2::Collector::Logger::JSONL';
    my $silent_class = 'T2H2_SilentLogger';
    ok(exists $loggers->{$jsonl_class},   'JSONL present (defined metadata)');
    ok(!exists $loggers->{$silent_class}, 'silent logger absent (undef metadata)');
    is(
        $loggers->{$jsonl_class}, [{jsonl_file => '/tmp/one.jsonl'}],
        'JSONL slot carries only the defined metadata'
    );
};

subtest '_send_logger_metadata still fires when every logger returns undef' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    my @sent;
    no warnings 'once', 'redefine';
    local *IPC::Manager::connect = sub {
        return bless {sent => \@sent}, 'T2H2_FakeClient_Empty';
    };
    *T2H2_FakeClient_Empty::peer_active  = sub { 1 };
    *T2H2_FakeClient_Empty::send_message = sub {
        my ($self, $to, $payload) = @_;
        push @{$self->{sent}} => $payload;
        return;
    };
    *T2H2_FakeClient_Empty::try_send_message  = sub { my $self = shift; $self->send_message(@_); 1 };
    *T2H2_FakeClient_Empty::set_send_blocking = sub { return };

    my $silent = T2H2_SilentLogger->new;

    my $c = Test2::Harness2::Collector::Test->new(
        stdout    => $devnull,
        ipcm_info => {fake => 1},
        ipc_parent  => 'harness', ipc_harness => 'harness',
        loggers   => [$silent],
    );
    $c->_instantiate_loggers();
    $c->_send_logger_metadata;

    is(scalar @sent,      1,               'message still fires with no metadata to report');
    is($sent[0]{kind},    'collector_artifacts', 'correct kind');
    is($sent[0]{loggers}, {},              'loggers is an empty hash');
};

subtest '_send_logger_metadata warns on IPC failure, does not propagate' => sub {
    open(my $devnull, '<', '/dev/null') or die $!;

    no warnings 'once', 'redefine';
    local *IPC::Manager::connect = sub {
        return bless {}, 'T2H2_FakeClient_Die';
    };
    local *T2H2_FakeClient_Die::peer_active        = sub { 1 };
    local *T2H2_FakeClient_Die::send_message       = sub { die "no route to peer\n" };
    local *T2H2_FakeClient_Die::try_send_message   = sub { my $self = shift; $self->send_message(@_); 1 };
    local *T2H2_FakeClient_Die::set_send_blocking  = sub { return };

    my $jsonl = Test2::Harness2::Collector::Logger::JSONL->new(
        ipcm_info => {}, output_file => '/tmp/x.jsonl',
    );
    my $c = Test2::Harness2::Collector::Test->new(
        stdout    => $devnull,
        ipcm_info => {fake => 1},
        ipc_parent  => 'harness', ipc_harness => 'harness',
        loggers   => [$jsonl],
    );
    $c->_instantiate_loggers();

    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings => @_ };

    my $ok = eval { $c->_send_logger_metadata; 1 };
    ok($ok,                                                             'does not propagate the exception');
    ok((grep { /Collector IPC send failed.*collector_artifacts/ } @warnings), 'warning surfaces');
};

subtest 'ipc_harness is required at construction - Collector' => sub {
    my $ok = eval {
        Test2::Harness2::Collector::Test->new(
            ipcm_info => {},
            launch    => ['perl', '-e', '1'],
        );
        1;
    };
    my $err = $@;
    ok(!$ok, 'croaks without ipc_harness');
    like($err, qr/ipc_harness/, 'error mentions ipc_harness');
};

# ===========================================================================
# collect_from_file tempfile cleanup (Windows spawn path)
# ===========================================================================

subtest 'collect_from_file cleans up tempfile even if require fails before decode_json_file' => sub {
    skip_all "fork required" unless $CAN_FORK;

    # Create a dummy tempfile; its content is irrelevant because we want the
    # child to die before decode_json_file ever runs.
    require File::Temp;
    my ($fh, $tmpfile) = File::Temp::tempfile(UNLINK => 0, SUFFIX => '.json');
    print $fh '{}';
    close $fh;
    ok(-f $tmpfile, "tempfile exists before test");

    my $pid = fork // die "fork: $!";
    if (!$pid) {
        # Force the next require of Test2::Harness2::Util::JSON to fail so
        # collect_from_file dies before decode_json_file ever runs.  This
        # simulates a module-load failure in the spawned collector child.
        delete $INC{'Test2/Harness2/Util/JSON.pm'};
        unshift @INC => sub {
            my (undef, $mod) = @_;
            die "simulated load failure\n" if $mod =~ m{Test2/Harness2/Util/JSON};
            return;
        };

        # collect_from_file will die during require; the Scope::Guard added by
        # the fix must unlink the file during stack unwind, before control
        # returns to this eval.
        eval { Test2::Harness2::Collector->collect_from_file($tmpfile) };
        POSIX::_exit(0);
    }

    waitpid($pid, 0);
    ok(!-f $tmpfile, "tempfile cleaned up even when collect_from_file dies before decode_json_file");
    unlink $tmpfile if -f $tmpfile;    # Safety: remove if test fails
};

done_testing;
