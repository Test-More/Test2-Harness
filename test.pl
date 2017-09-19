#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
use strict;
use warnings;

use Test2::Tools::Tiny;

my @search = ('t', 't2');
push @search => 'xt' if $ENV{AUTHOR_TESTING};

system($^X, '-Ilib', './scripts/yath', 'test', '-j2', @search);
my $exit1 = $?;
ok(!$exit1, "Passed tests when run by yath", "`yath -j2` exited with $exit1");

system($^X, '-Ilib', './scripts/yath', 'test', '-j2', '--no-fork', @search);
my $exit2 ||= $?;
ok(!$exit2, "Passed tests when run by yath", "`yath -j2 --no-fork` exited with $exit1");

done_testing;

# Normalize the exit value
exit(($exit1 || $exit2)? 255 : 0);
