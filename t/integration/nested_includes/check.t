use Test2::V0;

my %have = map {$_ => 1} @INC;

ok($have{'/foo'}, "/foo was added to \@INC");
ok($have{'/bar'}, "/bar was added to \@INC");
ok($have{'/baz'}, "/baz was added to \@INC");

done_testing;
