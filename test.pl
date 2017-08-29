#!/usr/bin/env perl
use strict;
use warnings;

use App::Yath::Command::test;

$ENV{T2_HARNESS_SPAWN_SCRIPT} = './scripts/yath-spawn';

my $cmd = App::Yath::Command::test->new(args => [@ARGV, 't']);
my $exit = $cmd->run;

# This makes sure it works with prove.
if ($ENV{HARNESS_ACTIVE}) {
    print "not " if $exit;
    print "ok - Passed tests when run by yath\n";
    print "1..1\n";
}

exit $exit;
