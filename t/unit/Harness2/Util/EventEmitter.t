use Test2::V0;
use Atomic::Pipe;
use Config;
use Cpanel::JSON::XS qw/decode_json/;
use POSIX qw/_exit/;
use Scalar::Util ();

use Test2::Harness2::Util::EventEmitter;

subtest 'writes JSON bursts readable by Atomic::Pipe' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    $emitter->emit_event(kind => 'test_event', note => 'hello');

    # Atomic::Pipe in mixed_data_mode: get_line_burst_or_data returns
    # ($type, $data). For write_message bursts the type is 'message'.
    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'got a message-type item');
    ok($msg, 'message has content');

    my $payload = decode_json($msg);
    is($payload->{facet_data}{harness}{kind}, 'test_event', 'custom kind field preserved');
    is($payload->{facet_data}{harness}{note}, 'hello',      'custom note field preserved');
    ok($payload->{event_id}, 'event_id populated');
    ok($payload->{stamp},    'stamp populated');
    ok(!exists $payload->{facet_data}{harness}{run_id},  'no ambient run_id stamped');
    ok(!exists $payload->{facet_data}{harness}{job_id},  'no ambient job_id stamped');
    ok(!exists $payload->{facet_data}{harness}{job_try}, 'no ambient job_try stamped');
};

subtest 'emit_event returns the event_id' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    my $id = $emitter->emit_event(kind => 'ping');
    ok($id, 'emit_event returns an event_id');
    like($id, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, 'event_id looks like a UUID');
};

subtest 'default stdout_pipe wraps STDOUT; stderr_pipe follows T2_HARNESS2_PIPE_COUNT' => sub {
    # Atomic::Pipe->from_fh only accepts actual pipe FDs, so wire up real
    # pipes and swap them in as STDOUT/STDERR while the emitter's init runs.
    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";
    pipe(my $err_r, my $err_w) or die "pipe stderr: $!";

    # PIPE_COUNT = 1 -> only stdout gets wrapped.
    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe wrapped from STDOUT');
        ok(!defined $e->stderr_pipe,
            'stderr_pipe stays empty when pipe count is 1 (merged)');
    }

    # PIPE_COUNT = 2 -> both stdout and stderr get wrapped.
    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 2;
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe wrapped from STDOUT');
        isa_ok($e->stderr_pipe, ['Atomic::Pipe'],
            'stderr_pipe wrapped from STDERR when pipe count is 2');
    }

    # Missing env var -> stderr_pipe stays empty (conservative default).
    {
        local *STDOUT = $out_w;
        local *STDERR = $err_w;
        local %ENV = %ENV;
        delete $ENV{T2_HARNESS2_PIPE_COUNT};
        my $e = Test2::Harness2::Util::EventEmitter->new;
        isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'stdout_pipe still defaults');
        ok(!defined $e->stderr_pipe,
            'stderr_pipe stays empty when env var is unset');
    }
};

subtest 'filehandle inputs are promoted to Atomic::Pipe' => sub {
    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";
    pipe(my $err_r, my $err_w) or die "pipe stderr: $!";

    my $e = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe => $out_w,
        stderr_pipe => $err_w,
    );
    isa_ok($e->stdout_pipe, ['Atomic::Pipe'], 'plain filehandle promoted for stdout');
    isa_ok($e->stderr_pipe, ['Atomic::Pipe'], 'plain filehandle promoted for stderr');
};

subtest 'pre-built Atomic::Pipe is used verbatim' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $e = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    is($e->stdout_pipe, $w, 'constructed pipe is stored without re-wrapping');
};

subtest 'std returns a process-wide cached instance, rebuilt after fork' => sub {
    skip_all "fork required" unless $Config{d_fork};

    pipe(my $out_r, my $out_w) or die "pipe stdout: $!";

    # Within one process std() hands back the same object on every call.
    my $first;
    my $second;
    {
        local *STDOUT = $out_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        $first  = Test2::Harness2::Util::EventEmitter->std;
        $second = Test2::Harness2::Util::EventEmitter->std;
    }
    is($first,  $second, 'same instance across two calls in the parent');
    isa_ok($first, ['Test2::Harness2::Util::EventEmitter'], 'std returns an emitter');

    # After a fork the child's first std() call sees the stale pid in the
    # cache and rebuilds.  Report the child's refaddr back via the parent
    # to compare.
    pipe(my $reply_r, my $reply_w) or die "pipe reply: $!";
    my $pid = fork // die "fork: $!";
    if (!$pid) {
        close $reply_r;
        local *STDOUT = $out_w;
        local $ENV{T2_HARNESS2_PIPE_COUNT} = 1;
        my $child = Test2::Harness2::Util::EventEmitter->std;
        syswrite($reply_w, Scalar::Util::refaddr($child) . "\n");
        close $reply_w;
        POSIX::_exit(0);
    }
    close $reply_w;
    waitpid($pid, 0);

    my $child_addr = <$reply_r>;
    chomp $child_addr;
    close $reply_r;

    isnt($child_addr, Scalar::Util::refaddr($first),
        'child rebuilds a distinct instance after fork');
};

subtest 'pid is populated in event' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);
    $emitter->emit_event(kind => 'test');

    my ($type, $msg) = $r->get_line_burst_or_data();
    my $payload = decode_json($msg);
    is($payload->{pid}, $$, 'pid matches current process');
};

subtest 'stderr_pipe receives sync marker when set' => sub {
    my ($r,    $w)    = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($se_r, $se_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe        => $w,
        stderr_pipe => $se_w,
    );

    my $id = $emitter->emit_event(kind => 'with_stderr');

    # STDOUT pipe should have the full JSON event
    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout pipe got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},                  $id,           'event_id matches return value');
    is($payload->{facet_data}{harness}{kind}, 'with_stderr', 'kind field preserved');

    # STDERR pipe should have just the tiny sync marker
    my ($se_type, $se_msg) = $se_r->get_line_burst_or_data();
    is($se_type, 'message', 'stderr pipe got a message');
    my $marker = decode_json($se_msg);
    is($marker->{event_id}, $id, 'stderr marker event_id matches');
    ok(!exists $marker->{facet_data}, 'stderr marker has no facet_data');
};

subtest 'emit_raw writes prebuilt event and stderr marker' => sub {
    my ($r,    $w)    = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($se_r, $se_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        stdout_pipe        => $w,
        stderr_pipe => $se_w,
    );

    my $raw = {event_id => 'fake-uuid-1234', stream_id => 7, facet_data => {assert => {pass => 1}}};
    my $ret = $emitter->emit_raw($raw);
    is($ret, 'fake-uuid-1234', 'emit_raw returns event_id');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},                    'fake-uuid-1234', 'event_id intact');
    is($payload->{stream_id},                   7,                'stream_id intact');
    is($payload->{facet_data}{harness}{event_id}, 'fake-uuid-1234', 'harness.event_id populated');

    my ($se_type, $se_msg) = $se_r->get_line_burst_or_data();
    is($se_type, 'message', 'stderr got a message');
    my $marker = decode_json($se_msg);
    is($marker->{event_id}, 'fake-uuid-1234', 'stderr marker event_id matches');
};

subtest 'emit_raw copies harness.event_id up to top level' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    my $raw = {facet_data => {harness => {event_id => 'from-harness'}, assert => {pass => 1}}};
    my $ret = $emitter->emit_raw($raw);
    is($ret, 'from-harness', 'propagated up to top level');
    is($raw->{event_id}, 'from-harness', 'event mutated in place');
};

subtest 'emit_raw generates an event_id when missing' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    my $raw = {facet_data => {assert => {pass => 1}}};
    my $ret = $emitter->emit_raw($raw);
    like($ret, qr/\A[0-9a-f]{8}-/i, 'returns generated UUID');
    is($raw->{event_id},                      $ret, 'top-level event_id set');
    is($raw->{facet_data}{harness}{event_id}, $ret, 'harness.event_id set');
};

subtest 'emit_raw croaks on top-vs-harness mismatch' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);
    my $emitter = Test2::Harness2::Util::EventEmitter->new(stdout_pipe => $w);

    my $raw = {
        event_id   => 'top-id',
        facet_data => {harness => {event_id => 'harness-id'}},
    };
    like(
        dies { $emitter->emit_raw($raw) },
        qr/event_id mismatch/,
        'croaks on mismatch',
    );
};

done_testing;
