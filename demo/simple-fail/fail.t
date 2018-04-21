#!/usr/bin/perl -w

use Test2::V0;

ok(0, "fail");
for (1 .. 100) {
    ok(1, "pass");
}

subtest foo => sub {
    ok(1, "sub-pass");
};

done_testing;
