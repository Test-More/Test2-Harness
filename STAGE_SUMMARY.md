# Stage 11 -- Log archive support (App::Yath2::LogArchive)

## Branch

- `plan-stage-11-log-archive`
- Base: `plan-stage-10-log-audit` (596f5a9c8)

## What landed (one commit)

1. **`App::Yath2::LogArchive: create / extract logs/ archives`**
   - `lib/App/Yath2/LogArchive.pm` with `create` and `extract`
     class methods.
   - Formats: **.tar.gz** (default; Archive::Tar + IO::Compress::Gzip),
     **.tar.bz2** (Archive::Tar + IO::Compress::Bzip2), **.zip**
     (gated behind Archive::Zip), **.7z** (shelled out to the
     `7z` binary on `$PATH`).
   - `HAS_ARCHIVE_TAR`, `HAS_GZIP`, `HAS_BZIP2`, `HAS_ARCHIVE_ZIP`,
     `HAS_7Z` compile-time constants gate optional deps.
   - Atomic writes via `$archive.pend` + rename.
   - Archive root is always `logs/` regardless of the source
     directory's name; extraction reproduces the same layout a
     live workdir exposes.
   - `supported_formats` / `format_is_supported` let callers pick
     a format that will work in the current environment.
   - `t/AI/unit/App/Yath2/LogArchive.t` exercises tar.gz
     round-trip, `.tgz` extension inference, error branches for
     missing logdir / missing archive / unknown format.

## Test results

- New test: `t/AI/unit/App/Yath2/LogArchive.t` -- 6 subtests, all
  passing.

## Deliberately out of scope for Stage 11

Per PLAN: no renderer changes, no command wiring. Consequently:

- No `yath archive` / `yath extract` command.
- No `--archive=...` option on `yath test` yet.
- Renderer code is untouched.

Stage 12 (renderers) and any later command that wants to package a
run's output will reach for `App::Yath2::LogArchive->create` then.

## Flip-back notes

- **Stage 12** may want to drive extraction from the command-side
  artifact-reading layer when the user feeds it a stored archive
  rather than a live workdir. `extract` returns a tempdir with
  CLEANUP; the layer can point at that directory as a drop-in
  for a live workdir.
- **Any future yath archive-family command** should call
  `create` and `format_is_supported` to produce a clear
  install-prompt error rather than let the archive write fail at
  runtime.
- **Stage 19 audit** should confirm that nothing in
  `old/lib/Test2/Harness2/Log.pm` silently returned, since the
  POD there is now replaced by this module's docs.
