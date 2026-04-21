use Test2::V0;

# Deferred (resolved-by: --log plumbing + -A / --no-plugins option
# activation + shared TestPlugin surface): stamps.t polls the yath
# --log JSONL stream and
# asserts every event carries a $event->{stamp} entry. The test
# uses -A + -pTestPlugin + -v + --no-plugins; its TestPlugin is
# the same one shared with plugin.t.
#
# Gaps blocking the port:
#   * --log / Tester log => 1 not plumbed (same as concurrency.t).
#   * -A / --no-plugins still commented-out Stage 6 options.
#   * The shared TestPlugin fixture lives under the plugin/ dir
#     (carried across alongside plugin.t).
#
# Once --log reaches the Tester, stamps.t is a short port: its
# only assertion is that every event has a stamp, which the new
# harness already produces.

plan skip_all => "stamps.t needs --log plumbing + -A + -pTestPlugin (Stage 6 + Stage 18 follow-up).";
