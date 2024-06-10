#!/usr/bin/perl -w

use Test2::V0;

ok(1, "pass") for 1 .. 1000;

subtest foo => sub {
    ok(1, "sub-pass") for 1 .. 1000;
};

done_testing;
