use Test2::V0;
use v5.38;

ok(1, "top pass");

subtest outer => sub {
    ok(1, "child ok");
    ok(0, "child fail");
};

done_testing;
