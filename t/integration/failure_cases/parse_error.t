use Test2::V0;

use goto::file(
    $ENV{FAILURE_DO_PASS}
    ? ['ok(1); done_testing;']
    : ['ok(; done_testing;']
);

die "Should not see this!";
