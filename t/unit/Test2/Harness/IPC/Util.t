use Test2::V0 -target => 'Test2::Harness::IPC::Util';

BEGIN {
    CLASS()->import(qw/pid_is_running set_procname inflate/);
}

subtest 'module loads' => sub {
    ok(CLASS(), "CLASS() is defined");
    is(CLASS(), 'Test2::Harness::IPC::Util', "CLASS() is the right package");
};

subtest 'pid_is_running' => sub {
    ok(pid_is_running($$), "current process ($$) is running");

    # A very large pid that should not exist
    is(pid_is_running(999999), 0, "non-existent pid 999999 returns 0");

    like(
        dies { pid_is_running(0) },
        qr/A pid is required/,
        "pid_is_running(0) confesses"
    );
};

subtest 'set_procname' => sub {
    my $orig = $0;
    local $ENV{T2_HARNESS_PROC_PREFIX};

    set_procname(set => ['test-worker']);
    like($0, qr/Test2-Harness/, "default prefix applied");
    like($0, qr/test-worker/,   "set name appears in \$0");

    set_procname(prefix => 'MyApp', set => ['server']);
    like($0, qr/^MyApp-server$/, "custom prefix used");

    set_procname(set => ['base'], append => ['extra']);
    like($0, qr/Test2-Harness/, "prefix present with append");
    like($0, qr/extra/,         "appended text present");

    # Restore original
    $0 = $orig;
};

subtest 'inflate' => sub {
    # undef / false value passes through unchanged
    my $undef;
    inflate($undef);
    is($undef, undef, "inflate(undef) is a no-op");

    # Already-blessed ref passes through
    my $blessed = bless {}, 'SomeArbitraryClass';
    inflate($blessed);
    isa_ok($blessed, ['SomeArbitraryClass'], "inflate on blessed ref is a no-op");

    # Hash with 'class' key gets instantiated
    my $ref = { class => 'Test2::Harness::IPC::Connection', protocol => 'Test2::Harness::IPC::Connection' };
    inflate($ref);
    isa_ok($ref, ['Test2::Harness::IPC::Connection'], "hash inflated into object using 'class' key");

    # Hash without 'class' uses fallback_class argument
    my $ref2 = { protocol => 'Test2::Harness::IPC::Connection' };
    inflate($ref2, 'Test2::Harness::IPC::Connection');
    isa_ok($ref2, ['Test2::Harness::IPC::Connection'], "hash inflated using fallback_class");

    # No class and no fallback dies
    like(
        dies { my $r = { foo => 1 }; inflate($r) },
        qr/No class to inflate/,
        "inflate without class or fallback dies"
    );
};

done_testing;
