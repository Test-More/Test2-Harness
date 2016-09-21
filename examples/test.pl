#!/usr/bin/env perl
use strict;
use warnings;

# Change this to list the directories where tests can be found. This should not
# include the directory where this file lives.

my @DIRS = ('./t2');

# PRELOADS GO HERE
# Example:
# use Moose;

###########################################
# Do not change anything below this point #
###########################################

use App::Yath;

# After fork, Yath will break out of this block so that the test file being run
# in the new process has as small a stack as possible. It would be awful to
# have a bunch of Test2::Harness frames on all stack traces.
T2_DO_FILE: {
    # Add eveything in @INC via -I so that using `perl -Idir this_file` will
    # pass the include dirs on to any tests that decline to accept the preload.
    my $yath = App::Yath->new(args => [(map { "-I$_" } @INC), '--exclude=use_harness', @DIRS, @ARGV]);

    # This is where we turn control over to yath.
    my $exit = $yath->run();
    exit($exit);
}

# At this point we are in a child process and need to run a test file specified
# in this package var.
my $file = $Test2::Harness::Runner::DO_FILE
    or die "No file to run!";

# Test files do not always return a true value, so we cannot use require. We
# also cannot trust $!
$@ = '';
do $file;
die $@ if $@;
exit 0;
