use Test2::V0;
# HARNESS-DURATION-SHORT

$\ = '|';
$, = '|';

is($\, '|', 'set $\\');
is($,, '|', 'set $,');

done_testing
