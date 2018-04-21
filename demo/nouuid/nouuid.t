use Test2::V0;
use Test2::Tools::Subtest qw/subtest_streamed subtest_buffered/;

ok(1, "An ok");
diag "A Diag";
note "A Note";

subtest_streamed streamed => sub {
    ok(1, "streamed ok");
};

subtest_buffered buffered => sub {
    ok(1, "buffered ok");
};

done_testing;
