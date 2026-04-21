use Test2::V0;

# Deferred (resolved-by: Formatter depth-decoration rebuild -- post-
# parity renderer redesign or move-to-t/AI rewrite):
# tapsubtest.t asserts specific verbose-formatter
# output lines for nested subtests using the old '[  PASS  ]  job 1
# +~buffered' shape with level indentation (| + / | | / | ^ / ^).
#
# The current App::Yath2::Renderer::Formatter emits a simpler
# "[ TAG    ] <text>" format with no job label column and no
# nesting / indentation marker column. Porting the assertions
# would require either:
#   * restoring the richer formatter output (decorated job-label
#     column + nesting depth column + tree corner markers), or
#   * rewriting the assertions against whatever the new verbose
#     line shape ends up being (at which point this would move
#     under t/AI/).
#
# Fixture carried across.

plan skip_all => "tapsubtest.t depends on the old verbose Formatter line shape with depth decorations (Renderer gap; Stage 18).";
