# EventPainter: paint events into a subtest graph

## Task

A new text renderer that turns a Test2 event into human-readable lines with a
subtest graph on the left — a single character per node indicating what each
line is (assert, fail, diag, note, ...), optionally colored. Plus a `t2h2_paint`
script that paints a whole events file. Driven by the `format` spec the user
wrote and the legacy `Test2::Formatter::Test2` + its `Composer` (for color and
tag choices). The output format is new (git-graph-like indentation); we
deliberately drop the legacy job-number / job-start-stop / status-line concerns.

## Components

- `App::Yath2::Renderer::Text::EventPainter` (first `App::Yath2` module in the
  repo). `new` takes `color` plus per-tag/facet theme overrides (and
  `:DEFAULT`). `paint($event, %opts)` returns lines; `parse_facet($facet, $item)`
  returns a render-meta hash (the spec's contract).
- `scripts/t2h2_paint` — reads an events file (plain jsonl or zstd, detected by
  leading bytes), paints each event, prints. `--color`/`--no-color` (auto by
  tty), `-v` (verbose: show plans etc.), width from `term_size`.

## Model

- **parse_facet** maps one facet item to `{key, text, verbosity, multiline,
  max_width, assert, fail, diag, debug, amnesty}`. `key` is the theme lookup
  (a tag like `PASS`/`DIAG`, or a facet name). Renderable facets: assert, info,
  errors, plan (verbose-only), control(halt), trace(debug). Everything else →
  undef (not rendered).
- **paint** orders facets (assert first, info last), filters by verbosity,
  applies two cross-facet rules in `_ordered_metas`: a failing assertion's
  `trace` becomes a debug line; an `amnesty` facet rewrites the assertion node
  to `! PASS !` (the `o` node) and suppresses the debug line. Then, for a
  subtest (event with `parent.children`), it emits the own-facet lines, a `\`
  branch marker, the children at `left_pad + 2`, and a `^` terminator.
- **Theme** (built-in default, user-overridable): nodes `* X o ! |`, colors
  echoing the legacy tag palette (PASS green, FAIL red, amnesty cyan, DIAG/
  STDERR yellow, DEBUG red, ...). Graph markers (`\ ^ +`) use a fixed graph
  color (bold bright_white).
- **Overflow**: a line that (with prefix+pad+node) exceeds `max_width`, is
  dumped flush-left between `+` markers. A multi-line message whose every line
  fits gets one node row per line.

## Decisions (please review)

- **Module namespace** `App::Yath2::Renderer::Text::EventPainter` per the spec.
  First App::Yath2 code in the repo — fits AGENTS' "App::Yath2 owns UI".
- **`paint` input** accepts a blessed event, a raw `{facet_data=>...}` event (as
  decoded from a file), or a bare facet_data hashref.
- **No top-level `^`.** The spec example ends with a `^` at column 0; I did not
  emit a terminator for the top level since it is not a subtest. Easy to add if
  you want the whole stream wrapped.
- **trace → debug only on a *failing* assertion.** A passing assert's trace is
  not shown (matches legacy). Amnesty suppresses it too.
- **plan is verbose-only** (verbosity 2); hidden by default so logs aren't
  noisy. `control` encoding and `about` are not rendered at all.
- **One trailing newline is stripped** from facet text (captured prints keep
  their `\n`); otherwise it produced a blank trailing graph row.
- **node_width**: the theme has a `node_width` slot but width is currently
  `length`-based (no unicode-width module installed). Multi-column nodes will
  not align perfectly yet.
- **Color default**: off for the class; the script turns it on when STDOUT is a
  tty.

## Things you may want to change

- The exact node/color for some tags (e.g. amnesty'd assertion's follow-on
  diag currently renders as `|`, not `!`).
- Whether `errors` from the auditor's process-exit (the failure summary) should
  paint at top level (currently they do, as `!`).
- The overflow `+` block currently keeps no prefix/pad on the content (spec:
  "content has no indentation"); confirm that's what you want for nested cases.
