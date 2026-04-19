use Test2::V0;
use Time::HiRes qw/time/;
use POSIX ();

use Test2::Harness2::Util qw/hub_truth load_module mod2file parse_exit tinysleep/;

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

done_testing;
