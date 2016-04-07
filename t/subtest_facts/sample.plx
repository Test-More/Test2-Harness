use Test2::Bundle::Extended;
use Test2::Tools::Subtest qw/subtest_buffered subtest_streamed/;

ok(1, "pass");

subtest_buffered foo => sub {
    ok(1, "pass");
    ok(2, "pass");

    subtest_buffered foo_nested => sub {
        ok(1, "pass");
        ok(2, "pass");
    };
};

subtest_streamed bar => sub {
    ok(1, "pass");
    ok(2, "pass");

    subtest_streamed bar_nested => sub {
        ok(1, "pass");
        ok(2, "pass");
    };
};

done_testing;
