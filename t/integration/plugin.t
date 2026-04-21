use Test2::V0;

# Deferred (resolved-by: Stage 6 option activation + plugin hook
# surface extension under App::Yath2::Role::Plugin + deprecation
# shim decision for removed hooks): plugin.t exercises a custom
# TestPlugin with
# hooks for duration_data, changed_files, get_coverage_tests,
# munge_files / munge_search, claim_file, and deprecated-hook
# warnings. The old plugin used the -p+TestPlugin + -A +
# --durations-threshold + --no-plugins + --changes-plugin flags.
#
# Two classes of gap:
#
#   * -A / --durations-threshold / --changes-plugin / --no-plugins
#     are all commented-out Stage-6 TODO options on
#     App::Yath2::Options::* ; Stage 6's priority set did not
#     include them.
#   * The hook surface the fixture drives (duration_data,
#     get_coverage_tests, munge_files, claim_file) is a superset
#     of what Test2::Harness2::Role::Plugin + App::Yath2::Role::
#     Plugin expose today (Stage 7). The deprecated-hook
#     warnings path (inject_run_data / handle_event / setup /
#     teardown) also needs a concrete porting decision -- those
#     hooks were removed, not kept with a deprecation shim.
#
# Fixture dir carried across so the test surface (including the
# local TestPlugin.pm) is available to the future port.

plan skip_all => "plugin.t needs -A/--durations-threshold/--changes-plugin/--no-plugins options + the full per-plugin hook surface (Stage 6 + Stage 18 follow-up).";
