use Test2::V0;
use utf8;

sub x {
is(
    [
        {
            unicode => 'a婧',
            a => 2,
            b => 1
        },
        'apple',
        'pear',
    ],
    [
        {
            unicode => 'b婧',
            a => 1,
            c => 1
        },
        'Apple',
        'Pear',
    ],
    "oops",
);
}

x();

subtest deep => \&x;

done_testing;
