package FooBarBaz;
use strict;
use warnings;

use Test2::V0;

is([caller(0)], [], "No caller at the flat test level");
is(__PACKAGE__, 'FooBarBaz', "inside main package");
like(__FILE__, qr/caller\.t$/, "__FILE__ is correct");
is(__LINE__, 10, "Got the correct line number");
is($@, '', '$@ set to empty string');

done_testing;