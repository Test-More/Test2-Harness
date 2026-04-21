use Test2::V0;

# Deferred: init.t asserts yath init writes a file named test.pl
# containing a "THIS IS A GENERATED YATH RUNNER TEST" marker. The
# new Command::init (Stage 13) writes a .yath.rc with a "# V2"
# marker instead -- a deliberate behaviour change for the V2 init
# contract.
#
# Resolved-by: Stage 19 final parity audit. The audit decides between
#   (a) rewriting the assertions against .yath.rc (test stays under
#       t/integration/ but diffs > 50% of body, likely moves to t/AI/),
#   (b) deleting the test file as obsolete-by-design, or
#   (c) bringing back test.pl as an optional scaffold and re-enabling
#       the old assertions.
# The fixture dir under t/integration/init/ is carried so option (c)
# has a place to land.

plan skip_all => "init.t asserts the old 'test.pl' scaffold; new Command::init writes .yath.rc instead (Stage 13 intentional behaviour change; Stage 19 audit to resolve).";
