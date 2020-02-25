use Test2::V0;
# HARNESS-DURATION-SHORT
skip_all "Test breaks Devel::Cover db" if $ENV{T2_DEVEL_COVER};

$\ = '|';
$, = '|';

is($\, '|', 'set $\\');
is($,, '|', 'set $,');

done_testing
