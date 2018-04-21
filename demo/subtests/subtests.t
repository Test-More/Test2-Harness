use Test2::V0;

subtest outer => sub {
    ok(1, "pass");
    subtest middle => sub {
        ok(1, "pass");
        subtest inner => sub {
            ok(1, "pass A");
            ok(1, "pass B");
            ok(1, "pass C");
        };
    };
};

done_testing;
