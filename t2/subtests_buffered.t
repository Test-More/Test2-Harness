# HARNESS-NO-STREAM
use strict;
use warnings;
use Test2::Tools::Tiny;
use Test2::Tools::Subtest qw/subtest_buffered/;
# HARNESS-DURATION-SHORT

subtest_buffered foo => sub {
    subtest_buffered bar => sub {
        ok(1, 'baz');
    };
};

done_testing;
