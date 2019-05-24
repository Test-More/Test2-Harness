#!perl

# This test can be used to validate the yath test --retry feature since you need the test to fail initially but pass the second time around.
# You do this by touching t/fail_once which causes a fail but then removes the file so it passes the second time.
# If you want to test a repeated retry, you can touch t/fail_repeatedly at which point it will fail indefinitely.
#
# Example:
#
# touch t/fail_once ; yath test -v --retry 1 t/fail.t
# touch t/fail_repeatedly ; yath test --retry 100 t/fail.t

use strict;
use warnings;

use Test::More;

my $fail_once_file = 't/fail_once';
my $fail_many_file = 't/fail_repeatedly';

ok(!-e $fail_once_file, "$fail_once_file is there.")
    or diag explain "Removing $fail_once_file";
unlink $fail_once_file;

ok(!-e $fail_many_file, "$fail_many_file is there.");

done_testing();

END {
    unlink $fail_once_file;
}
