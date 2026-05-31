use Test2::V0;
use v5.38;
use POSIX ();

# A subtest installs the io_events tie; then a top-level print passes through
# the tie to the real handle, and the process exits hard (no buffer flush).
subtest s => sub { ok(1, "in subtest") };

print STDOUT "PASSTHROUGH-MARKER\n";

POSIX::_exit(0);
