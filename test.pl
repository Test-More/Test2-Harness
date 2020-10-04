#!/usr/bin/env perl
# HARNESS-NO-RUN
use strict;
use warnings;

use lib 'lib';
use App::Yath::Util qw/find_yath/;

print "1..2\n";

$ENV{'YATH_SELF_TEST'} = 1;
system($^X, find_yath(), '-D', 'test', '--qvf', '-r1', '--default-search' => './t', '--default-search' => './t2', @ARGV);
my $exit1 = $?;

$ENV{T2_NO_FORK} = 1;
system($^X, find_yath(), '-D', 'test', '--qvf', '-r1', '--default-search' => './t', '--default-search' => './t2', @ARGV);
my $exit2 = $?;

print "not " if $exit1;
print "ok 1 - Passed tests when run by yath (allow fork)\n";
print STDERR "yath exited with $exit1" if $exit1;

print "not " if $exit2;
print "ok 2 - Passed tests when run by yath (no fork)\n";
print STDERR "yath exited with $exit2" if $exit2;

exit($exit1 || $exit2 ? 255 : 0);
