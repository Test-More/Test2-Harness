use Test2::V0;

ok($ENV{T2_HARNESS_JOB_IS_TRY} > 0, "Not the first try");

done_testing;
