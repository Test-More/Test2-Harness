use Test2::V0;
use Atomic::Pipe;
use Cpanel::JSON::XS qw/decode_json/;

use Test2::Harness2::Util::EventEmitter;

subtest 'writes JSON bursts readable by Atomic::Pipe' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        pipe   => $w,
        job_id => 'svc-job-1',
    );

    $emitter->emit_event(kind => 'test_event', note => 'hello');

    # Atomic::Pipe in mixed_data_mode: get_line_burst_or_data returns
    # ($type, $data). For write_message bursts the type is 'message'.
    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'got a message-type item');
    ok($msg, 'message has content');

    my $payload = decode_json($msg);
    is($payload->{facet_data}{harness}{job_id}, 'svc-job-1', 'job_id baked in');
    ok(!defined $payload->{facet_data}{harness}{run_id}, 'run_id undef for service event');
    is($payload->{facet_data}{harness}{kind}, 'test_event', 'custom kind field preserved');
    is($payload->{facet_data}{harness}{note}, 'hello',      'custom note field preserved');
    ok($payload->{event_id}, 'event_id populated');
    ok($payload->{stamp},    'stamp populated');
};

subtest 'run_id included when provided' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        pipe   => $w,
        job_id => 'job-2',
        run_id => 'run-abc',
    );

    $emitter->emit_event(kind => 'lifecycle');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'got a message-type item');

    my $payload = decode_json($msg);
    is($payload->{facet_data}{harness}{run_id}, 'run-abc', 'run_id baked in');
    is($payload->{facet_data}{harness}{job_id}, 'job-2',   'job_id baked in');
};

subtest 'emit_event returns the event_id' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(pipe => $w);

    my $id = $emitter->emit_event(kind => 'ping');
    ok($id, 'emit_event returns an event_id');
    like($id, qr/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i, 'event_id looks like a UUID');
};

subtest 'pipe is required' => sub {
    like(
        dies { Test2::Harness2::Util::EventEmitter->new() },
        qr/'pipe' is required/,
        'croaks when pipe is missing',
    );
};

subtest 'pid is populated in event' => sub {
    my ($r, $w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(pipe => $w);
    $emitter->emit_event(kind => 'test');

    my ($type, $msg) = $r->get_line_burst_or_data();
    my $payload = decode_json($msg);
    is($payload->{pid}, $$, 'pid matches current process');
};

subtest 'stderr_pipe receives sync marker when set' => sub {
    my ($r,    $w)    = Atomic::Pipe->pair(mixed_data_mode => 1);
    my ($se_r, $se_w) = Atomic::Pipe->pair(mixed_data_mode => 1);

    my $emitter = Test2::Harness2::Util::EventEmitter->new(
        pipe        => $w,
        stderr_pipe => $se_w,
        job_id      => 'job-se',
    );

    my $id = $emitter->emit_event(kind => 'with_stderr');

    # STDOUT pipe should have the full JSON event
    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout pipe got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},                    $id,           'event_id matches return value');
    is($payload->{facet_data}{harness}{job_id}, 'job-se',      'job_id in harness facet');
    is($payload->{facet_data}{harness}{kind},   'with_stderr', 'kind field preserved');

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
        pipe        => $w,
        stderr_pipe => $se_w,
    );

    my $raw = {event_id => 'fake-uuid-1234', stream_id => 7, facet_data => {assert => {pass => 1}}};
    my $ret = $emitter->emit_raw($raw);
    is($ret, 'fake-uuid-1234', 'emit_raw returns event_id');

    my ($type, $msg) = $r->get_line_burst_or_data();
    is($type, 'message', 'stdout got a message');
    my $payload = decode_json($msg);
    is($payload->{event_id},  'fake-uuid-1234', 'event_id intact');
    is($payload->{stream_id}, 7,                'stream_id intact');

    my ($se_type, $se_msg) = $se_r->get_line_burst_or_data();
    is($se_type, 'message', 'stderr got a message');
    my $marker = decode_json($se_msg);
    is($marker->{event_id}, 'fake-uuid-1234', 'stderr marker event_id matches');
};

done_testing;
