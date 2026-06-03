use Test2::V0;
use v5.38;

use File::Temp qw/tempdir/;
use IO::Socket::UNIX;
use Time::HiRes qw/time/;

use Test2::Harness2::Util::Zstd::FrameBuffer;
use Test2::Harness2::Util::JSON qw/decode_json/;
use Test2::Harness2::Service::Sampler;

# The sampler samples every tick but reports only when a metric (cpu or memory),
# rounded up to the nearest 5%, changes from the last sent: increases
# immediately, decreases only once they have held for decrease_delay. A message
# is sent when EITHER metric triggers and carries both rounded values.

package FakeSource {
    sub new ($class, @samples) { bless {s => [@samples]}, $class }    # each = [cpu, mem]
    sub sample ($self) {
        my $p = shift @{$self->{s}};
        return {cpu_pct => $p->[0], mem_pct => $p->[1], ncpu => 4};
    }
}

sub sampler (%args) {
    return Test2::Harness2::Service::Sampler->new(
        workdir        => tempdir(CLEANUP => 1),
        harness_socket => '/unused/in/this/test',
        interval       => 0.2,
        decrease_delay => 1.0,
        %args,
    );
}

# Drive one metric's policy the way service_tick does: decide, then commit if it
# fired. Returns the rounded value when it would send, else undef.
sub feed ($s, $name, $raw, $now) {
    my $r = $s->_round_up_5($raw);
    my $t = $s->_metric_triggers($name, $r, $now);
    $s->_commit_metric($name, $r) if $t;
    return $t ? $r : undef;
}

subtest round_up_5 => sub {
    my $s = sampler();
    is($s->_round_up_5(0),    0,   "0 -> 0");
    is($s->_round_up_5(0.1),  5,   "0.1 -> 5");
    is($s->_round_up_5(5),    5,   "exact 5 stays 5");
    is($s->_round_up_5(50),   50,  "exact 50 stays 50");
    is($s->_round_up_5(51),   55,  "51 -> 55");
    is($s->_round_up_5(99.9), 100, "99.9 -> 100");
    is($s->_round_up_5(100),  100, "100 -> 100");
};

subtest initial_and_increase => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 42, 1), 45,    "first reading sent, rounded up");
    is(feed($s, 'cpu', 43, 2), undef, "same 5% bucket sends nothing");
    is(feed($s, 'cpu', 46, 3), 50,    "increase reported immediately");
    is(feed($s, 'cpu', 61, 4), 65,    "another increase, immediately");
};

subtest decrease_must_persist => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 48, 0), 50, "start at 50");
    is(feed($s, 'cpu', 41, 10.0), undef, "decrease (->45) not trusted yet");
    is(feed($s, 'cpu', 41, 10.5), undef, "still inside the 1s window");
    is(feed($s, 'cpu', 41, 10.9), undef, "still inside the 1s window");
    is(feed($s, 'cpu', 41, 11.0), 45,    "held >= 1s -> reported");
    is(feed($s, 'cpu', 41, 11.2), undef, "steady at 45 -> nothing");
};

subtest equal_resets_window => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 58, 0),   60,    "start at 60");
    is(feed($s, 'cpu', 41, 1.0), undef, "decrease window opens");
    is(feed($s, 'cpu', 57, 1.5), undef, "back to 60 (==last) breaks the window");
    is(feed($s, 'cpu', 41, 2.0), undef, "window restarts");
    is(feed($s, 'cpu', 41, 2.9), undef, "only 0.9s in");
    is(feed($s, 'cpu', 41, 3.0), 45,    "1s into the restarted window -> sent");
};

subtest increase_during_decrease_window => sub {
    my $s = sampler();
    is(feed($s, 'cpu', 58, 0),   60,    "start at 60");
    is(feed($s, 'cpu', 41, 1.0), undef, "decrease window opens");
    is(feed($s, 'cpu', 72, 1.2), 75,    "increase during the window fires immediately");
    is(feed($s, 'cpu', 41, 2.0), undef, "fresh decrease window");
    is(feed($s, 'cpu', 41, 2.5), undef, "still within it");
};

subtest memory_uses_the_same_policy => sub {
    my $s = sampler();
    is(feed($s, 'mem', 12, 0),    15,    "memory rounded up and sent");
    is(feed($s, 'mem', 11, 1),    undef, "same bucket, nothing");
    is(feed($s, 'mem', 16, 2),    20,    "memory increase immediate");
    is(feed($s, 'mem', 6,  10.0), undef, "memory decrease not trusted yet");
    is(feed($s, 'mem', 6,  11.0), 10,    "memory decrease held >= 1s -> sent");
};

subtest either_metric_triggers_a_send => sub {
    my ($a, $b) = IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
    $b->blocking(0);

    # [cpu, mem]: t1 both initial; t2 mem up only; t3 nothing; t4 cpu up only.
    my $s = sampler(source => FakeSource->new([42, 10], [43, 11], [43, 11], [80, 11]));
    $s->{conn} = $a;

    my $fb = Test2::Harness2::Util::Zstd::FrameBuffer->new;
    my $read_one = sub {
        my $deadline = time + 1;
        while (time < $deadline) {
            my $buf = '';
            my $n = sysread($b, $buf, 65536);
            if ($n) { $fb->push_bytes($buf); my ($r) = $fb->drain; return decode_json($r->{payload}) if $r }
            select(undef, undef, undef, 0.01);
        }
        return undef;
    };
    my $nothing = sub { my $buf = ''; my $n = sysread($b, $buf, 65536); return !$n };

    $s->{next_at} = time - 1; $s->service_tick;
    my $m1 = $read_one->();
    is($m1->{load}{cpu_pct}, 45, "t1 reports rounded cpu");
    is($m1->{load}{mem_pct}, 10, "t1 reports rounded mem");

    $s->{next_at} = time - 1; $s->service_tick;    # mem 11->15 increase
    my $m2 = $read_one->();
    is($m2->{load}{mem_pct}, 15, "t2 memory increase triggered the send");
    is($m2->{load}{cpu_pct}, 45, "...carrying the current rounded cpu too");

    $s->{next_at} = time - 1; $s->service_tick;    # nothing changed
    ok($nothing->(), "t3 sends nothing when neither metric changes");

    $s->{next_at} = time - 1; $s->service_tick;    # cpu 43->80 increase
    my $m4 = $read_one->();
    is($m4->{load}{cpu_pct}, 80, "t4 cpu increase triggered the send");
    is($m4->{load}{mem_pct}, 15, "...carrying the current rounded mem too");
};

subtest stops_when_connection_breaks => sub {
    my ($a, $b) = IO::Socket::UNIX->socketpair(AF_UNIX, SOCK_STREAM, 0) or die "socketpair: $!";
    my $s = sampler(source => FakeSource->new([10, 10], [20, 10], [30, 10]));
    $s->{conn} = $a;

    $s->{next_at} = time - 1; $s->service_tick;    # sends
    close($b);
    $s->{next_at} = time - 1; $s->service_tick;    # cpu increase -> write fails
    ok($s->{service_stopped}, "sampler stops when the harness connection breaks");
};

done_testing;
