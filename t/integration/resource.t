use Test2::V0;

# Deferred (resolved-by: --log JSONL Tester plumbing +
# Stage 6 -R/--resource option activation + STDERR-to-log funneling):
# resource.t drives a custom Resource module
# (resource/lib/Resource.pm) through yath -R+Resource -j4 and
# polls the JSONL log for STDERR lines of the form
# "<pid> - <action>: <resource> - <slot>" then asserts the
# observed sequence of Assigned / No Slots / Release events.
#
# Multiple layers of gap:
#
#   * --log JSONL is not plumbed through the Tester (same gap
#     as concurrency.t and smoke.t).
#   * The -R / --resource option is still commented-out in
#     App::Yath2::Options::Resource (Stage 6 TODO) and the
#     custom-resource loader chain it triggers is not wired to
#     Command::test.
#   * The resource's STDERR side effects go through a harness
#     feed that the test relies on being funneled into the JSONL
#     log. That path also isn't set up.
#
# Fixture dir (resource/lib/Resource.pm plus the .tx files) is
# carried across so the test can be unblocked once -R lands.

plan skip_all => "resource.t depends on --log JSONL + -R+Resource option + harness STDERR-to-log funneling (Stage 6 + Stage 18 follow-up).";
