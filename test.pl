#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
use strict;
use warnings;

system($^X, '-Ilib', './scripts/yath', 'test', 't', @ARGV);
my $exit = $?;

# This makes sure it works with prove.
if ($ENV{HARNESS_ACTIVE}) {
    require Test2::Tools::Tiny;
    Test2::Tools::Tiny::ok(!$exit, "Passed tests when run by yath");
    Test2::Tools::Tiny::done_testing();
}

exit $exit;
