use Test2::V0;

# TODO Stage 18: port the SmokePlugin fixture into the new plugin
# surface and the --smoke-exists option Stage 6 left commented out
# (see Options/Finder TODO markers). The fixture dir for this test
# lives next to it under t/integration/smoke/ and carries a local
# SmokePlugin.pm under smoke/lib/.
#
# The original test relies on three pieces that are not yet wired:
#
#   * yath --log to produce the harness JSONL event stream the test
#     polls for harness_job_start events. The Tester's log => 1
#     plumbing is not ported either.
#   * --ext=tx (Finder option gated behind the Stage 6 TODO).
#   * -p+SmokePlugin driving the finder-side smoke-first ordering.
#
# Once these land, replace the skip with the original body. The
# fixture dir is already in the tree so only the test file needs
# edits.

plan skip_all => "smoke ordering test needs --log JSONL + --ext + -pSmokePlugin (Stage 6 / Stage 12 / Stage 15 follow-ups).";
