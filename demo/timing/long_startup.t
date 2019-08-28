# HARNESS-NO-TIMEOUT
BEGIN { sleep 40 }
use Test2::V0;

ok(1, "Now");

ok(1, "Later");

done_testing;
