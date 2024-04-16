#!/usr/bin/perl -w

use Test2::Tools::Tiny;
use Test2::Tools::Subtest qw/subtest_buffered/;

ok(0, "fail");
for (1 .. 10) {
    ok(1, "pass");
}

subtest_buffered foo_pass => sub {
    ok(1, "sub-pass");
    ok(1, "sub-pass");
    ok(1, "sub-pass");
};

subtest_buffered foo_fail => sub {
    ok(1, "sub-pass");
    ok(0, "sub-fail");
    ok(1, "sub-pass");
};

done_testing;
