use Test2::V0;
use v5.38;

ok(1, "top level pass");

subtest outer => sub {
    ok(1, "child a");
    ok(1, "child b");

    subtest inner => sub {
        ok(1, "grandchild");
    };
};

done_testing;
