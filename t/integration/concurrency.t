use Test2::V0;

# TODO Stage 18 / Stage 12 follow-up: this test polls a yath --log
# JSONL file for harness_job_start / harness_job_exit events and
# asserts the observed (start, exit) ordering respects the -j4 / -j2
# concurrency cap.
#
# The artifact-reading layer (App::Yath2::ArtifactReader) landed in
# Stage 12 but the Tester's log => 1 plumbing (which piped an
# explicit --log path into yath and then wrapped the resulting file
# in Test2::Harness2::Util::File::JSONL for polling) is not ported
# yet. The CLI also does not expose a --log option today -- those
# live on the old Run options set that is still commented out.
#
# Fixtures (concurrency/*.tx) are in-tree so the test can be
# unblocked by landing the log option, wiring Tester.pm log => 1,
# and restoring the assertions.

plan skip_all => "concurrency ordering test needs yath --log + Tester log=>1 plumbing (Stage 12 / Stage 18 follow-up).";
