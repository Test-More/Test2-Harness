#!/usr/bin/env perl
# HARNESS-NO-PRELOAD
# HARNESS-CAT-LONG
use strict;
use warnings;

system($^X, '-Ilib', './scripts/yath', 'test', 't');
my $exit1 = $?;
print STDERR "yath exited with $exit1\n" if $exit1;

system($^X, '-Ilib', './scripts/yath', 'test', 't', '--no-fork');
my $exit2 ||= $?;
print STDERR "yath --no-fork exited with $exit2\n" if $exit2;

# This makes sure it works with prove.
print "1..2\n";

print "not " if $exit1;
print "ok 1 - Passed tests when run by yath\n";

print "not " if $exit2;
print "ok 2 - Passed tests when run by yath --no-fork\n";


# Normalize the exit value
exit(($exit1 || $exit2)? 255 : 0);
