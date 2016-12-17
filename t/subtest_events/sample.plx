use Test2::Bundle::Extended;
use Test2::Tools::Subtest qw/subtest_buffered subtest_streamed/;

ok(1, "pass 1");

subtest_buffered foo_buffered => sub {
    ok(1, "pass 2.1");
    ok(2, "pass 2.2");

    subtest_buffered foo_buffered_nested => sub {
        ok(1, "pass 2.3.1");
        ok(2, "pass 2.3.2");
    };
};

subtest_streamed bar_streamed => sub {
    ok(1, "pass 3.1");
    ok(2, "pass 3.2");

    subtest_streamed bar_streamed_nested => sub {
        ok(1, "pass 3.3.1");
        ok(2, "pass 3.3.2");
    };
};

done_testing;
