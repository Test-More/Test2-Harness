use Test2::V0 -target => 'Test2::Harness::Util::Term';
# HARNESS-DURATION-SHORT

use ok $CLASS => qw/USE_ANSI_COLOR/;

imported_ok(qw/USE_ANSI_COLOR/);

is(USE_ANSI_COLOR(), in_set(0, 1), "USE_ANSI_COLOR returns true or false");

done_testing;
