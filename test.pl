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
ok(!$exit1, "Passed tests when run by yath", "`yath test -j2` exited with $exit1");

system($^X, '-Ilib', './scripts/yath', 'test', '-j2', '--no-fork', @search);
my $exit2 ||= $?;
ok(!$exit2, "Passed tests when run by yath", "`yath test -j2 --no-fork` exited with $exit2");

system($^X, '-Ilib', './scripts/yath', 'start', '-j2');
my $exit3 ||= $?;
ok(!$exit3, "started a persistant yath", "`yath -j2 --no-fork` exited with $exit3");

system($^X, '-Ilib', './scripts/yath', 'run', @search);
my $exit4 ||= $?;
ok(!$exit4, "Tests passed", "`yath run` exited with $exit4");

system($^X, '-Ilib', './scripts/yath', 'stop');
my $exit5 ||= $?;
ok(!$exit5, "stopped a persistant yath", "`yath -j2 --no-fork` exited with $exit5");

done_testing;

# Normalize the exit value
exit(($exit1 || $exit2)? 255 : 0);
