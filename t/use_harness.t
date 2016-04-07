#!/usr/bin/env perl
use strict;
use warnings;

use App::Yath;

my @dirs;
if (-d './t' && -d './t2') {
    @dirs = ('./t', './t2');
}
elsif (-d '../t' && -d '../t2') {
    @dirs = ('../t', '../t2');
}
else {
    die "Could not find test dirs";
}

print "1..2\n";

T2_DO_FILE: {
    print "\n# Running all tests WITHOUT preload...\n";
    my $yath = App::Yath->new(args => [(map { "-I$_" } @INC), '--exclude=use_harness', @dirs, @ARGV]);
    my $files = join ':' => @{$yath->files};
    die "Missing test files" if grep { $files !~ m{\Q$_\E} } qw{
        t2/fork_tap.t
        t2/taint.t
        t2/Test-Builder-Tester.t
    };
    my $exit = $yath->run();
    print(($exit ? "not " : "") .  "ok 1 - Ran tests without preload\n");

    print "\n# Running all tests WITH preload...\n";
    $yath = App::Yath->new(args => [(map { "-I$_" } @INC), '--exclude=use_harness', @dirs, '-LTest2::Harness', @ARGV]);
    die "Missing test files" if grep { $files !~ m{\Q$_\E} } qw{
        t2/fork_tap.t
        t2/taint.t
        t2/Test-Builder-Tester.t
    };
    my $exit2 = $yath->run();
    print(($exit2 ? "not " : "") . "ok 2 - Ran tests with preload\n");

    exit($exit + $exit2);
}

my $file = $Test2::Harness::Runner::DO_FILE
    or die "No file to run!";

# Test files do not always return a true value, so we cannot use require. We
# also cannot trust $!
$@ = '';
do $file;
die $@ if $@;
exit 0;
