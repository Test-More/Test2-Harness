#!/usr/bin/perl -w

use Test2::V0;
ok(1, "pass");

subtest foo => sub {
    ok(1, "sub-pass");
    ok(0, "sub-fail");
};

done_testing;
