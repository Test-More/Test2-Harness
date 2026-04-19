use Test2::V0;
use Time::HiRes qw/time/;
use POSIX ();

use File::Temp qw/tempfile tempdir/;
use Fcntl qw/LOCK_EX LOCK_NB/;

use Test2::Harness2::Util qw{
    apply_encoding
    close_file
    hub_truth
    load_module
    lock_file
    mod2file
    parse_exit
    tinysleep
    unlock_file
};

subtest 'mod2file' => sub {
    is(mod2file('Foo::Bar::Baz'), 'Foo/Bar/Baz.pm', "converts :: to / and adds .pm");
    is(mod2file('Simple'),        'Simple.pm',      "single-level module");

    like(
        dies { mod2file(undef) },
        qr/No module name/,
        "dies on undef"
    );
};

subtest 'parse_exit - clean exit' => sub {
    my $parsed = parse_exit(0);
    is($parsed->{err}, 0, "err is 0");
    is($parsed->{sig}, 0, "sig is 0");
    is($parsed->{dmp}, 0, "dmp is 0");
    is($parsed->{all}, 0, "all is 0");
};

subtest 'parse_exit - exit code' => sub {
    # exit(42) => $? == 42 << 8 == 10752
    my $parsed = parse_exit(42 << 8);
    is($parsed->{err}, 42,      "err is 42");
    is($parsed->{sig}, 0,       "no signal");
    is($parsed->{dmp}, 0,       "no core dump");
    is($parsed->{all}, 42 << 8, "all preserves raw value");
};

subtest 'parse_exit - signal' => sub {
    # killed by signal 9, no core dump
    my $parsed = parse_exit(9);
    is($parsed->{err}, 0, "err is 0");
    is($parsed->{sig}, 9, "sig is 9");
    is($parsed->{dmp}, 0, "no core dump");
};

subtest 'parse_exit - signal with core dump' => sub {
    # signal 11 (SEGV) + core dump flag (128)
    my $parsed = parse_exit(11 | 128);
    is($parsed->{err}, 0,  "err is 0");
    is($parsed->{sig}, 11, "sig is 11");
    ok($parsed->{dmp}, "core dump flag set");
};

subtest 'parse_exit - requires argument' => sub {
    like(
        dies { parse_exit(undef) },
        qr/exit value is required/,
        "dies on undef"
    );
};

subtest 'hub_truth' => sub {
    my $hub   = {nested => 2, hid => 'h'};
    my $trace = {frame  => ['Foo', 'foo.t', 42]};

    is(hub_truth({hubs  => [$hub], trace => $trace}), $hub,   "hubs[0] preferred over trace");
    is(hub_truth({trace => $trace}),                  $trace, "trace used when no hubs");
    is(hub_truth({hubs  => [], trace => $trace}),     $trace, "empty hubs falls back to trace");
    is(hub_truth({}), {}, "empty hash returned when neither present");
};

subtest 'tinysleep - sleeps approximately the requested duration' => sub {
    my $start = time;
    tinysleep(0.1);
    my $elapsed = time - $start;
    cmp_ok($elapsed, '>=', 0.08, 'slept at least ~0.1s (with generous slack)');
    cmp_ok($elapsed, '<',  1.0,  'did not sleep absurdly long');
};

subtest 'tinysleep - no-op on undef / zero / negative' => sub {
    my $start = time;
    tinysleep(undef);
    tinysleep(0);
    tinysleep(-1);
    my $elapsed = time - $start;
    cmp_ok($elapsed, '<', 0.05, 'returns immediately');
};

subtest 'tinysleep - returns early when a signal arrives' => sub {
    # Schedule a SIGALRM to fire shortly after we enter the nap, then
    # ask for a much longer sleep. select() returns on EINTR so we
    # should come back well before the full duration.
    local $SIG{ALRM} = sub { 1 };
    require Time::HiRes;
    Time::HiRes::ualarm(50_000);    # 50 ms
    my $start = time;
    tinysleep(5);                   # would be 5 s if signals were swallowed
    my $elapsed = time - $start;
    Time::HiRes::ualarm(0);         # cancel any leftover (shouldn't be any)
    cmp_ok($elapsed, '<', 1.0, 'SIGALRM interrupted the nap');
};

subtest 'load_module - loads a module once and is idempotent' => sub {
    my $name = 'Test2::Harness2::Collector::Logger::JSONL';

    my $ret = load_module($name);
    is($ret, $name, 'returns the module name');
    ok($INC{mod2file($name)}, 'module is in %INC after load');

    # Second call must not die or re-require.
    my $ret2 = load_module($name);
    is($ret2, $name, 'idempotent second call');
};

subtest 'load_module - dies on a missing module' => sub {
    my $ok  = eval { load_module('Bogus::Module::ThatDoesNotExist'); 1 };
    my $err = $@;
    ok(!$ok, 'dies when module cannot be found');
    like($err, qr/Bogus[\\\/]Module[\\\/]ThatDoesNotExist\.pm/);
};

subtest 'load_module - requires a name' => sub {
    like(
        dies { load_module(undef) },
        qr/required/,
        'dies on undef',
    );
    like(
        dies { load_module('') },
        qr/required/,
        'dies on empty string',
    );
};

subtest 'apply_encoding - utf8' => sub {
    my ($fh, $path) = tempfile(UNLINK => 1);
    apply_encoding($fh, 'utf8');
    print $fh "\x{263A}";
    close $fh;

    open(my $rh, '<:raw', $path) or die $!;
    my $bytes = do { local $/; <$rh> };
    close $rh;
    is($bytes, "\xe2\x98\xba", 'utf8 layer emitted three-byte encoding');
};

subtest 'apply_encoding - no-op on false' => sub {
    my ($fh) = tempfile(UNLINK => 1);
    my $ok = eval { apply_encoding($fh, undef); apply_encoding($fh, ''); 1 };
    ok($ok, 'returns without changing anything on undef/empty');
};

subtest 'close_file - succeeds without name' => sub {
    my ($fh) = tempfile(UNLINK => 1);
    my $ok = eval { close_file($fh); 1 };
    ok($ok, 'closes an open handle cleanly');
};

subtest 'close_file - already-closed handle dies' => sub {
    my ($fh) = tempfile(UNLINK => 1);
    close($fh);
    like(
        dies { close_file($fh, 'thing.txt') },
        qr/Could not close file 'thing\.txt'/,
        'diagnostic includes the name'
    );
};

subtest 'lock_file / unlock_file - round trip on a path' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/lockme";

    my $fh = lock_file($path);
    ok($fh, 'got a locked handle');

    # Second non-blocking lock attempt in this process shares advisory
    # locks on the same handle but not between handles.
    open(my $other, '>>', $path) or die $!;
    my $got_second = flock($other, LOCK_EX | LOCK_NB);
    ok(!$got_second, 'second independent handle cannot acquire exclusive lock');
    close($other);

    unlock_file($fh);
    close($fh);

    # After unlock, a fresh handle should lock immediately.
    open(my $after, '>>', $path) or die $!;
    ok(flock($after, LOCK_EX | LOCK_NB), 'lock available after unlock');
    close($after);
};

subtest 'lock_file - accepts an already-open handle' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $path = "$dir/lockme2";

    open(my $fh, '>>', $path) or die $!;
    my $locked = lock_file($fh);
    is($locked, $fh, 'returns the same handle it was given');
    unlock_file($fh);
    close($fh);
};

done_testing;
