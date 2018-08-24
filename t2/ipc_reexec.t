# HARNESS-NO-FORK
BEGIN { $INC{'Test2/Formatter/Stream.pm'} && exec($^X, $0); };
# Force into stdout
BEGIN { delete $ENV{T2_STREAM_FILE} };

use Test::Builder;
use Test2::V0;

ok 1, "test runs correctly in IPC mode";
done_testing;
