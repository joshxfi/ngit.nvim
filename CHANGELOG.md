# Changelog

## Unreleased

- Made streaming remote output chunk-safe and bounded without repeated
  whole-buffer copies.
- Bounded cached preview models by both entry count and estimated memory.
- Made theme-derived diff colors refresh after colorscheme changes while
  preserving explicit user overrides.
- Kept file-state circle markers foreground-only so themes cannot add boxed
  backgrounds around them.
- Added `0` as the default direct shortcut for focusing the selected diff.
- Prevented manual side-by-side selection when the preview is too narrow.
- Split session refresh, mapping, and command orchestration into focused
  modules and added reproducible median-based parser benchmarks.
- Added aligned side-by-side diffs with responsive unified fallback, full-line
  backgrounds, intraline emphasis, source line numbers, and syntax highlighting.
- Replaced raw Git plumbing in previews with structured file and hunk headers.
- Added changed-file navigation and a split/unified diff toggle.
- Added field-aware highlighting across status, branch, commit, and stash rows.
- Added optional split-statusline suppression while the ngit tab is active,
  including lualine integration and restoration when leaving or closing.
- Fixed stale previews and async job ownership races during rapid navigation
  and refreshes.
- Made diff presentation lazy, removed duplicate model construction, and made
  intraline matching linear with UTF-8-safe byte ranges.
- Added bounded whole-file unstage, quoted rename/copy path handling, corrected
  preview split geometry, narrow-screen fallback, and early minimum-size
  validation.
- Made save-triggered refreshes status-only, batched streaming console redraws,
  and generated help from configured mappings and action metadata.
- Increased diff contrast with theme-derived red/green full-line backgrounds,
  stronger intraline regions, and matching colored line-number markers.
- Added a default multi-panel dashboard with persistent Changes, Branches,
  Commits, and Stashes context alongside the selected patch.
- Added panel cycling, numeric panel focus, independent panel selection, and a
  context-sensitive action footer.
- Kept former layout option values as compatibility aliases for the dashboard;
  patches now remain on the right.
- Added paginated commit history and lazy commit patch previews.
- Added local and remote branch browsing, comparison previews, switching,
  creation, merged-only deletion, merge, and rebase.
- Added multi-line commit creation and amend support.
- Added stash creation, preview, apply, pop, and guarded drop.
- Added streaming fetch, fast-forward-only pull, and push progress.
- Added merge, rebase, cherry-pick, and revert detection with continue/abort.
- Added ours/theirs conflict resolution and commit cherry-picking.
