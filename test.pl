#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
use strict;
use warnings;

use App::Yath::Command::test;

$ENV{T2_HARNESS_SPAWN_SCRIPT} = './scripts/yath-spawn';

my $cmd = App::Yath::Command::test->new(args => [@ARGV, 't']);
my $exit = $cmd->run;

# This makes sure it works with prove.
if ($ENV{HARNESS_ACTIVE}) {
    require Test2::Tools::Tiny;
    Test2::Tools::Tiny::ok(!$exit, "Passed tests when run by yath");
    Test2::Tools::Tiny::done_testing();
}

exit $exit;
