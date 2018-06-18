use Test2::V0;

ok(1, "pass A");

is(
    { a => 1, b => 2, c => [qw/a b c/] },
    { a => 2, b => 3, c => [qw/x y z/] },
    "Deep Fail"
);

ok(1, "pass B");

done_testing;
