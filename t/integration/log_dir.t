use Test2::V0;

# Deferred (resolved-by: Stage 6 --log-dir / -L option activation +
# Command::test user-requested top-level JSONL logger wiring):
# log_dir.t passes --log-dir=<path> and -L to yath
# and verifies a single .jsonl file lands in that directory.
#
# Neither --log-dir nor -L are wired up yet: both options sit
# commented out in App::Yath2::Options::Run.pm (Stage 6 TODO
# block). The underlying log-file production also needs Command::
# test to route a JSONL logger into the workdir's logs/ tree
# based on the CLI option, which it does not do today (the
# renderer path wires its own per-job JSONL but not a
# user-requested top-level one).
#
# Fixture dir carried across so a future port has a place to land.

plan skip_all => "log_dir.t depends on --log-dir / -L options (commented in Options/Run.pm; Stage 6 + Stage 18 follow-up).";
