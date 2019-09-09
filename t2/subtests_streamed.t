# HARNESS-NO-STREAM
use strict;
use warnings;
use Test2::Tools::Tiny;
use Test2::Tools::Subtest qw/subtest_streamed/;
# HARNESS-DURATION-SHORT

subtest_streamed foo => sub {
    subtest_streamed bar => sub {
        ok(1, 'baz');
    };
};

done_testing;
