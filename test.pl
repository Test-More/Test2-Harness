#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
use strict;
use warnings;

system($^X, '-Ilib', './scripts/yath', 'test', 't', @ARGV);
my $exit = $?;

# This makes sure it works with prove.
print "1..1\n";
print "not " if $exit;
print "ok 1 - Passed tests when run by yath\n";
print STDERR "yath exited with $exit" if $exit;

# Normalize the exit value
exit($exit ? 255 : 0);
