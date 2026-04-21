use Test2::V0;

# Deferred (resolved-by: Command::projects implementation --
# Stage 13 still a stub; filename label gap fixed in Stage 18):
# projects.t asserts `yath projects` enumerates a
# set of sibling project dirs (foo / bar / baz) under a common
# root and runs yath in each, with output lines like
# "PASSED .*foo.*t.*pass.tx".
#
# App::Yath2::Command::projects is a stub today (Stage 13) -- its
# run() just prints "not yet implemented" and exits 2. Per the
# Stage 13 summary the enumeration shape (config file,
# convention, CLI list) isn't decided yet so there's nothing to
# assert against.
#
# Separately, as with persist.t, the "PASSED .*file.tx" pattern
# depends on the renderer growing a filename label column which
# the Default renderer does not have today (see
# lib/App/Yath2/Renderer/Default.pm::_job_label).
#
# Fixture dir carried across (t/integration/projects/*) so the
# test can be reinstated when the projects command lands.

plan skip_all => "projects.t depends on Command::projects (still a stub) + filename-labeled renderer output (Stage 13 + Stage 18 follow-up).";
