use Test2::V0;
# HARNESS-JOB-SLOTS 2

ok(!$ENV{T2_HARNESS_JOB_CONCURRENCY}, "T2_HARNESS_JOB_CONCURRENCY is not set");
ok($ENV{T2_HARNESS_MY_JOB_CONCURRENCY}, "Have job concurrency set ($ENV{T2_HARNESS_MY_JOB_CONCURRENCY})");

if ($ENV{T2_HARNESS_MY_JOB_COUNT} > 1) {
    is($ENV{T2_HARNESS_MY_JOB_CONCURRENCY}, 2, "Have job concurrency set to 2 with harness count > 1");
}

done_testing;
