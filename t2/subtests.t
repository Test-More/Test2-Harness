#!/usr/bin/perl

use Test2::V0;
use Time::HiRes qw/sleep/;

ok(1, "pass");


subtest out => sub {
    ok(1, "pass");
    ok(1, "pass");

    subtest in => sub {
        for (1 .. 10) {
            ok(1, "pass $_");
            sleep 0.1;
        }
    };

    ok(1, "pass");
    ok(1, "pass");
};

done_testing;
