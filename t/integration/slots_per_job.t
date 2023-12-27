use Test2::V0;

skip_all "This test only works under Test2::Harness" unless $ENV{TEST2_HARNESS_ACTIVE};

ok(!$ENV{T2_HARNESS_JOB_CONCURRENCY}, "T2_HARNESS_JOB_CONCURRENCY is not set");
ok($ENV{T2_HARNESS_MY_JOB_CONCURRENCY}, "Have job concurrency set ($ENV{T2_HARNESS_MY_JOB_CONCURRENCY})");
ok($ENV{T2_HARNESS_MY_JOB_CONCURRENCY} >= 1, "Have job concurrency set to a positive number ($ENV{T2_HARNESS_MY_JOB_CONCURRENCY})");

done_testing;
