use Test2::V0;

# TODO Stage 18: the current scripts/yath launcher REPLACES @INC with
# the value of $ENV{T2_HARNESS_INCLUDES} instead of appending to it:
#
#     @INC = split /;/, $ENV{T2_HARNESS_INCLUDES} if $ENV{T2_HARNESS_INCLUDES};
#
# old/'s launcher pushed the new entries onto @INC instead. That
# means nested yath invocations (a yath test spawning another yath
# test) can't currently pass dev libs through via
# T2_HARNESS_INCLUDES without clobbering the outer yath's own
# @INC. This test validates the outer-test scenario from old/
# verbatim; until the launcher is fixed there is no way to make it
# pass in the new tree.

plan skip_all => "nested T2_HARNESS_INCLUDES handling regressed in scripts/yath; restore the append-style behaviour from old/scripts/yath, then remove this skip. See TODO at top of file.";
