use Test2::V0;

# TODO Stage 18: includes.t verifies yath's @INC assembly across
# -I, -b (blib), -l (lib), --unsafe-inc, -D (dev-lib), and the
# not-perl shebang handling. The test chdirs into
# t/integration/includes/ and runs yath with a set of permutations
# asserting the child test's @INC matches a specific ordering.
#
# The permutations that need wiring:
#
#   * `-I` / `-l` / `-b` / `--unsafe-inc` are all commented out
#     TODO-ed options in App::Yath2::Options::Tests +
#     App::Yath2::Options::Run (Stage 6).
#   * The child test (default.tx) asserts against
#     App::Yath2->app_path, a method the old App::Yath2 exposed
#     but the new one has not yet grown.
#   * A shebang-based `not-perl.sh` fixture uses $ENV{YATH_PERL}
#     to locate perl; the YATH_PERL handling in new Command::test
#     / Harness2 is not yet exercised.
#
# Fixtures are carried across so the test can be unblocked once
# the options and app_path land.

plan skip_all => "includes.t depends on -I/-l/-b/--unsafe-inc options + App::Yath2->app_path (Stage 6 + Stage 18 follow-up).";
