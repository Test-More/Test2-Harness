use strict;
use warnings;

use Test2::Plugin::Cover;
use Test2::V0;

my $path;
BEGIN {
    $path = __FILE__;
    $path =~ s{[^/]+\.t$}{}g;
    unshift @INC => "${path}lib/";
}

subtest foo => sub {
    require TestMod1;
    ok(TestMod1->foo, "foo");
};

done_testing;
