use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use IO::Socket::UNIX;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Service::Sampler;

# The sampler's service_tick samples at most once per interval and writes a
# one-way system_load frame to its harness connection.

package FakeSource {
    sub new { bless {n => 0}, shift }
    sub sample ($self) { return {cpu_pct => 42, seq => ++$self->{n}} }
}

my ($a, $b) = IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, 0)
    or die "socketpair: $!";

my $sampler = Test2::Harness2::Service::Sampler->new(
    workdir        => tempdir(CLEANUP => 1),
    harness_socket => '/unused/in/this/test',
    interval       => 0.2,
    source         => FakeSource->new,
);

# Wire the outbound connection directly (skip service_on_start's real connect).
$sampler->{conn}    = $a;
$sampler->{next_at} = time - 1;    # force a sample now

sub read_frame ($fh) {
    $fh->blocking(0);
    my $fb = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $deadline = time + 2;
    while (time < $deadline) {
        my $buf = '';
        my $n = sysread($fh, $buf, 65536);
        if ($n) { $fb->push_bytes($buf); my ($rec) = $fb->drain; return decode_json($rec->{payload}) if $rec; }
        select(undef, undef, undef, 0.01);
    }
    return undef;
}

subtest samples_and_reports => sub {
    $sampler->service_tick;
    my $msg = read_frame($b);
    ok($msg, "a frame was written") or return;
    is($msg->{request}, 'system_load', "it is a system_load request");
    is($msg->{load}{cpu_pct}, 42, "carries the snapshot");
    is($msg->{load}{seq}, 1, "first sample");
    ok($sampler->{next_at} > time, "next_at advanced into the future");
};

subtest throttles_within_interval => sub {
    # next_at is in the future now; an immediate tick must not sample again.
    $sampler->service_tick;
    $b->blocking(0);
    my $buf = '';
    my $n = sysread($b, $buf, 65536);
    ok(!$n, "no frame written before the interval elapses");
};

subtest stops_when_connection_breaks => sub {
    close($b);    # peer gone -> next write fails
    $sampler->{next_at} = time - 1;
    $sampler->service_tick;
    ok($sampler->{service_stopped}, "sampler stops when the harness connection breaks");
};

done_testing;
