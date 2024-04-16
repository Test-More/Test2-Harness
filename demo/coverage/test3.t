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

use TestMod1;
use TestMod2;

subtest foo => sub {
    Test2::Plugin::Cover->set_from(['foo', __FILE__, __LINE__]);
    open(my $fh, '<', "${path}file1.txt") or die "Could not open file: $!";
    ok(TestMod1->foo, "foo");
    Test2::Plugin::Cover->clear_from();
};

ok(TestMod2->foo, "foo");
ok(TestMod2->bar, "bar");
open(my $fh, '<', "${path}file2.txt") or die "Could not open file: $!";

subtest bar => sub {
    Test2::Plugin::Cover->set_from(['bar', __FILE__, __LINE__]);
    open(my $fh, '<', "${path}file1.txt") or die "Could not open file: $!";
    ok(TestMod1->bar, "bar");
    Test2::Plugin::Cover->clear_from();
};

done_testing;
