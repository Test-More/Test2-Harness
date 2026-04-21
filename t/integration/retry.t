use Test2::V0;

# TODO Stage 18: retry.t exercises the -r3 / --retry N / --project
# options and polls the harness log for the harness_final facet to
# assert the retry sequence (tried 2/2, 2/4, file=retry.tx,
# status=YES/NO).
#
# The --retry / -r option and --project pre-command are still
# commented-out in App::Yath2::Options::* (Stage 6 TODO). Even
# with those activated, the Retry mechanism itself -- requeueing
# a failed job and accumulating a retry trace on the harness-side
# log -- is not carried across from old/ in this tree. The
# `harness_final.retried` facet shape the test asserts against
# would need to be produced.
#
# Fixture dirs (retry, retry-symlinks, retry-timeout) carried
# across so the shape is available when retry support lands.

plan skip_all => "retry.t depends on --retry / --project + harness_final.retried facet (Stage 6 + retry-mechanism port follow-up).";
