#!perl

use strict;
use warnings;

use Test::More;

note "valid note [“”\xff\xff]";
note "valid note [“”]";

diag "valid diag [“”\xff\xff]";
diag "valid diag [“”]";

print "valid stdout [“”\xff\xff]\n";
print "valid stdout [“”]\n";

print STDERR "valid stderr [“”\xff\xff]\n";
print STDERR "valid stderr [“”]\n";

ok 1;

done_testing();
