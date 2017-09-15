package FooBarBaz;
use strict;
use warnings;

use Test2::V0;

open(my $fh, '<', __FILE__) or die "Could not open this file!: $!";
my @end = <$fh>;
close($fh);

is($end[-1], 'done_testing', "no semicolon or newline is present at the end of this file");

done_testing