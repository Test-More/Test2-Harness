use Test2::V0;

use Test2::Harness2::Util qw/mod2file parse_exit/;

subtest 'mod2file' => sub {
    is(mod2file('Foo::Bar::Baz'), 'Foo/Bar/Baz.pm', "converts :: to / and adds .pm");
    is(mod2file('Simple'), 'Simple.pm', "single-level module");

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
    is($parsed->{err}, 42, "err is 42");
    is($parsed->{sig}, 0, "no signal");
    is($parsed->{dmp}, 0, "no core dump");
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
    is($parsed->{err}, 0, "err is 0");
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

done_testing;
