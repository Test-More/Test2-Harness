# HARNESS-DURATION-SHORT
use strict;
use warnings;

use Test2::V0;
use Test2::API qw/test2_formatter/;

ok(1, "Minimal result");

sub {
    my $ctx = context();

    diag "Formatter: " . test2_formatter();

    $ctx->release;
}->();


$ENV{T2_HARNESS_JOB_IS_TRY} //= 0;
$ENV{FAIL_ONCE}             //= 0;
$ENV{FAIL_ALWAYS}           //= 0;

diag "JOB_IS_TRY  = $ENV{T2_HARNESS_JOB_IS_TRY}";
diag "FAIL_ONCE   = $ENV{FAIL_ONCE}";
diag "FAIL_ALWAYS = $ENV{FAIL_ALWAYS}";

ok(0, "Should fail once") if $ENV{FAIL_ONCE} && $ENV{T2_HARNESS_JOB_IS_TRY} < 1;
ok(0, "Should fail always") if $ENV{FAIL_ALWAYS};

done_testing();
