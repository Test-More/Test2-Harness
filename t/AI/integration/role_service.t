use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use Time::HiRes qw/sleep time/;

use Test2::Harness2::Util::Socket qw/connect_unix write_frame/;
use Test2::Harness2::Util::Zstd qw/compress_blob/;
use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/encode_json decode_json/;

# A minimal service consuming Role::Service, exercised over its real socket.
package My::Service {
    use parent -norequire;
    use Object::HashBase qw{ <workdir <name };
    use Role::Tiny::With;
    with 'Test2::Harness2::Role::Service';

    sub request_handler_ping ($self, $payload, $conn) {
        return {ok => 1, pong => $payload->{n}};
    }
}

# Send one request, return the decoded response.
sub request ($path, $payload) {
    my $sock = connect_unix($path);
    write_frame($sock, compress_blob(encode_json($payload)));

    my $fb = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $deadline = time + 10;
    while (time < $deadline) {
        my $buf = '';
        my $n = sysread($sock, $buf, 65536);
        if ($n) {
            $fb->push_bytes($buf);
            for my $rec ($fb->drain) { return decode_json($rec->{payload}) }
        }
        sleep 0.01;
    }
    die "no response within timeout";
}

my $dir = tempdir(CLEANUP => 1);
my $svc = My::Service->new(workdir => $dir, name => 'demo');
my $path = $svc->service_socket_path;
is($path, "$dir/demo.socket", "socket path is workdir/name.socket");

my $pid = fork // die "fork: $!";
unless ($pid) {
    $svc->run;
    POSIX::_exit(0);
}

# Wait for the service to bind.
my $deadline = time + 10;
sleep 0.01 until -S $path || time > $deadline;
ok(-S $path, "service bound its socket");

my $resp = request($path, {request => 'ping', n => 7});
is($resp, {ok => 1, pong => 7}, "dispatched to request_handler_ping and got a response");

my $stop = request($path, {request => 'stop'});
is($stop->{ok}, 1, "stop request acknowledged");

waitpid($pid, 0);
ok(!-e $path, "socket cleaned up after the loop ended");

done_testing;
