use Test2::V0;

ok(defined($ENV{$_}), "env var $_ is set") for qw{
    HARNESS_ACTIVE
    TEST2_HARNESS_ACTIVE
    TEST2_ACTIVE
    TEST_ACTIVE
    TEST2_RUN_DIR
    TEST2_JOB_DIR
    T2_HARNESS_JOB_IS_TRY
    T2_HARNESS_JOB_NAME
    T2_HARNESS_JOB_FILE
};

done_testing;
