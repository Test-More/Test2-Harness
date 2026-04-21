use Test2::V0;

subtest foo => sub {
    subtest bar => sub {
        subtest baz => sub {
            ok($ENV{FAILURE_DO_PASS}, "check env");
        };
    };
};

done_testing;
