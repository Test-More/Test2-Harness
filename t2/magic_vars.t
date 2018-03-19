use Test2::V0;

$\ = '|';
$, = '|';

is($\, '|', 'set $\\');
is($,, '|', 'set $,');

done_testing
