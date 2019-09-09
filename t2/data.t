use Test2::V0;
# HARNESS-DURATION-SHORT

is(
    [<DATA>],
    ["foo\n", "bar\n", "baz\n"],
    "Got data section"
);

done_testing;

__DATA__
foo
bar
baz
