#!/usr/bin/perl -w

use Test2::V0;

ok(0, "fail");

ok(1, "pass") for 1 .. 1000;

subtest foo => sub {
    ok(1, "sub-pass") for 1 .. 1000;
    ok(0, "fail");
};

done_testing;
