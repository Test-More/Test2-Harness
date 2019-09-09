use Test2::V0;
# HARNESS-DURATION-SHORT

my $file = __FILE__;
my $line = __LINE__ + 1;
sub throw { die("xxx") };

is(
    dies { throw() },
    "xxx at $file line $line.\n",
    "Got exception as expected"
);

done_testing;
