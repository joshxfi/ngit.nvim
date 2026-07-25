# ngit.nvim

A fast, review-first Git interface for Neovim.

The name reads as **n-git**—Neovim Git—in the same spirit as `nvim`.

ngit opens a dedicated dashboard with changes, branches, recent commits, and
stashes in persistent panels on the left and a lazy-loaded structured diff on
the right. It is designed for the loop that happens most often while coding:
inspect changes, move through hunks, and stage exactly what should be committed
without losing repository context.

## Highlights

- Staged, unstaged, untracked, renamed, deleted, and conflicted files.
- Side-by-side diffs with aligned old/new lines and a polished unified fallback.
- Full-line and intraline change highlighting, plus source syntax highlighting.
- Field-aware highlighting for file states, branches, commits, and stashes.
- Persistent Changes, Branches, Commits, and Stashes panels.
- Context-sensitive actions that use your configured mappings.
- File and hunk navigation without leaving Neovim.
- Whole-file and hunk staging/unstaging.
- Paginated commit history with lazy commit patches.
- Local and remote branches with comparison previews and safe switching.
- Multi-line commit editor, amend support, and stash workflows.
- Streaming fetch, fast-forward pull, and push console.
- Merge/rebase/cherry-pick detection and conflict-side resolution.
- Confirmed, section-aware discard for staged, unstaged, and untracked files.
- Rename-aware staging, unstaging, and discarding.
- Push offers `--set-upstream` instead of failing on a fresh branch.
- Asynchronous Git operations; the editor event loop is never blocked.
- Stale-request cancellation, debounced previews, and a bounded LRU cache.
- NUL-delimited porcelain-v2 parsing for unusual filenames.
- No runtime dependencies and no global mappings.

## Requirements

- Neovim 0.10 or newer
- Git

## Installation

With lazy.nvim:

```lua
{
  "joshxfi/ngit",
  cmd = {
    "NGit",
    "NGitLog",
    "NGitBranches",
    "NGitStashes",
    "NGitClose",
    "NGitRefresh",
  },
  keys = {
    { "<leader>ng", "<cmd>NGit<cr>", desc = "Open ngit" },
  },
  opts = {},
}
```

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/joshxfi/ngit" })

vim.keymap.set("n", "<leader>ng", "<cmd>NGit<cr>", {
  desc = "Open ngit",
})
```

## Usage

Run `:NGit` from any file in a Git repository. An optional directory can be
provided:

```vim
:NGit
:NGit ~/code/project
```

The recommended launcher is `<leader>ng`: `n` for Neovim and `g` for Git.
ngit deliberately does not create a global mapping by default, so it cannot
conflict with your existing leader keys.

The selected section defines the comparison:

| Section | Comparison |
| --- | --- |
| Staged | `HEAD` to index |
| Unstaged | index to worktree |
| Untracked | empty file to worktree |
| Conflicts | index to worktree |

From the file panel, `s` and `u` act on the whole file. From a hunk in the diff
panel, they stage or unstage only that hunk. Hunk operations are deliberately
disabled when the preview was truncated. `a` and `A` stage or unstage
everything at once.

`X` discards the selected change and always names what it is about to do:

| Section | Result of `X` |
| --- | --- |
| Unstaged | worktree returns to the staged content |
| Staged | index and worktree both return to `HEAD` |
| Untracked | the file is deleted |
| Conflicts | refused; resolve with `co`/`ct` or abort the operation |

Renames occupy two index slots, so staging, unstaging, and discarding all act
on the old and new path together. A file with unsaved changes in a loaded
buffer is never overwritten.

Focus dashboard areas without closing ngit:

| Mapping | View |
| --- | --- |
| `0` | Selected diff |
| `1` or `gs` | Working-tree changes |
| `2` or `gb` | Local and remote branches |
| `3` or `gl` | Commit history |
| `4` or `gz` | Stashes |

Use `<Tab>` and `<S-Tab>` to cycle panels, `j` and `k` to move inside the
focused panel, and `<CR>` to focus the preview. `<Esc>` returns from the preview
to the active panel. Commit history is paginated; press `L` to load another
page. Branch previews show the branch diff against `HEAD`, while the current
branch previews its tip commit.

### Default mappings

All mappings are buffer-local.

| Key | Action |
| --- | --- |
| `q` | Close ngit |
| `r` | Refresh |
| `j` / `k` | Next/previous item in the focused panel |
| `<CR>` | Focus the selected diff |
| `<Esc>` | Return from the preview to the active panel |
| `<Tab>` / `<S-Tab>` | Next/previous dashboard panel |
| `1` / `2` / `3` / `4` | Focus Changes/Branches/Commits/Stashes |
| `]c` / `[c` | Next/previous hunk |
| `]f` / `[f` | Next/previous changed file in a multi-file preview |
| `dv` | Toggle side-by-side/unified diff |
| `s` | Stage file or current hunk |
| `u` | Unstage file or current hunk |
| `a` | Stage every change (Changes panel) |
| `A` | Unstage every change (Changes panel) |
| `X` | Discard the selected change after confirmation |
| `o` | Open selected file |
| `/` | Filter changed files |
| `0` | Focus the selected diff |
| `<leader>e` | Return to the active side panel |
| `?` | Show help |
| `x` | Switch branch, or copy a selected commit hash |
| `n` | Create a branch or stash |
| `a` / `p` | Apply/pop a stash (Stashes panel) |
| `D` | Delete a merged local branch or drop a stash, with confirmation |
| `c` / `C` | Create/amend a commit using a `gitcommit` buffer |
| `f` / `U` / `P` | Fetch, fast-forward pull, or push |
| `co` / `ct` | Resolve a conflict with ours/theirs and stage it |
| `gC` / `gA` | Continue/abort the active Git operation |
| `m` / `R` | Merge the selected branch / rebase onto it |
| `v` | Cherry-pick the selected commit |

## Configuration

Configuration is optional:

```lua
require("ngit").setup({
  context = 3,
  debounce_ms = 45,
  refresh_debounce_ms = 120,
  max_diff_bytes = 2 * 1024 * 1024,
  cache_entries = 24,
  max_cache_bytes = 32 * 1024 * 1024,
  commit_limit = 150,
  diff_layout = "auto",
  side_by_side_min_width = 80,
  file_panel_width = 0.32,
  hide_statusline = true,
  auto_refresh = true,
  confirm_discard = true,
  mappings = {
    toggle_diff = "dv", -- set any mapping to false to disable it
  },
})
```

The example shows the main layout and resource controls. Defaults work without
calling `setup()`; see `:help ngit-configure` for every option and the table
above for all default mappings.

`dashboard` is the only rendered layout. The former `vertical`, `stacked`, and
`auto` values remain accepted as compatibility aliases and normalize to the
dashboard so the patch always stays on the right.

`diff_layout` accepts `"auto"`, `"side_by_side"`, or `"unified"`. Auto uses
aligned old/new panes when the preview is at least `side_by_side_min_width`
columns wide, and switches to the polished unified view in narrower layouts.
Added and removed rows use theme-derived full-line backgrounds, with stronger
intraline highlights and matching colored line-number markers. The colors are
recomputed after `:colorscheme` changes.

When `hide_statusline` is enabled, ngit hides the statusline row while its
dedicated tab is active. Native split statuslines are collapsed into one blank
global row, and lualine rendering is temporarily suspended when lualine is
loaded. Your previous statusline mode is restored whenever you leave or close
ngit, so status content does not jump between dashboard splits.

The dashboard adapts its preview to the available width: `auto` uses a
side-by-side source view when there is room and a formatted unified view on
narrow screens. Extremely small editor areas fail early with a clear minimum
size message instead of leaving behind a partially constructed split layout.

Automatic refresh is event-aware. Saving a buffer reloads working-tree status
and its preview only; focus and shell events perform a full repository refresh.
This keeps commit, branch, and stash history queries off the common save path.

The preview cache is bounded independently by entry count and estimated memory.
An item larger than `max_cache_bytes` is displayed but not retained. Set any
mapping to `false` to disable it. Configuration is validated when `setup()` is
called.

## Commands

- `:NGit [directory]` — open or focus ngit.
- `:NGitRefresh` — refresh the active view.
- `:NGitClose` — close the active view and restore the previous tab.
- `:NGitLog` — open ngit and focus Commits.
- `:NGitBranches` — open ngit and focus Branches.
- `:NGitStashes` — open ngit and focus Stashes.
- `:checkhealth ngit` — check Neovim, Git, and configuration.

## Safety

Read operations run with `GIT_OPTIONAL_LOCKS=0`. Commands use argument arrays
and literal pathspecs rather than a shell. Every discard names its exact effect
and asks for confirmation by default, so an untracked file is only deleted when
that is what was requested. A file with unsaved changes in a loaded buffer is
never overwritten, and open buffers are rechecked after any mutation.

Failures report what Git actually said. Several ordinary refusals — including
`nothing to commit` — arrive on standard output rather than standard error, so
both are considered before falling back to an exit code. Committing checks for
unresolved conflicts and an empty index before opening an editor.

Branch deletion uses Git's merged-only `-d` behavior. Pull is deliberately
fast-forward-only. ngit never force-pushes, and aborting an active Git operation
requires confirmation. Remote commands disable invisible terminal credential
prompts and show their complete progress in a cancellable console.

## Performance

The four dashboard collections load independently and asynchronously. File and
object patches are loaded only for the active selection; changing panel focus
does not reload collection data. Rapid selections are debounced, superseded
jobs are terminated, and cached patches are bounded by `cache_entries`. Large
previews are truncated at `max_diff_bytes`. Cached previews are also bounded by
`max_cache_bytes`, so a handful of large patches cannot exhaust the intended
cache budget. Each raw patch is parsed once into the presentation model;
switching split/unified views does not invoke Git again. The last few
presentation models are kept as well, so moving back over a file redraws
without rebuilding them.

Source line numbers are drawn through `'statuscolumn'` rather than one virtual
text mark per line, so a patch costs nothing for rows that are never displayed.
Syntax highlighting is skipped for very large previews. Detecting an
in-progress merge, rebase, cherry-pick, or revert stats the Git directory
instead of spawning a process on every refresh, and saving a file outside the
repository does not trigger one at all.

The included deterministic microbenchmark uses generated fixtures, warm-up
runs, and the median of seven timed samples:

```sh
make benchmark
```

Representative results from an Apple M4 with 24 GB RAM, Neovim 0.12.4, on
2026-07-26:

| Workload | Fixture | Median |
| --- | ---: | ---: |
| Porcelain-v2 status parser | 10,000 files | 6.4 ms |
| Commit parser | 10,000 commits | 18.0 ms |
| Branch parser | 10,000 refs | 11.7 ms |
| Diff presentation | 4 KiB near-identical lines | 0.37 ms |
| Diff presentation | 4,000-line patch | 14.7 ms |
| Preview render, unified | 4,000-line patch | 5.7 ms |
| Preview render, side by side | 4,000-line patch | 6.7 ms |

The parser rows measure in-process parsing and diff-model construction, not Git
process startup or disk I/O. The two preview-render rows do include drawing:
buffer population, highlight extmarks, and the source-number gutter, which is
the cost paid on every selection change.

Moving that gutter from one virtual-text extmark per line to `'statuscolumn'`
is worth measuring directly. Against the same fixture and machine:

| Preview render | Before | After |
| --- | ---: | ---: |
| Unified | 12.5 ms | 5.7 ms |
| Side by side | 15.2 ms | 6.7 ms |

The parser figures above are unchanged by that work; they read faster than
earlier recordings only because the machine was quieter, so treat them as a
fresh baseline rather than an improvement. All of these are reference points
for regression checks rather than performance guarantees; run `make benchmark`
on your own machine when comparing changes.

## Development

```sh
make check
make format-check
make benchmark
```

Tests use temporary real Git repositories and a headless Neovim instance. They
cover parsing, caching, diff extraction, file and hunk staging, commits,
branches, stashes, local remote synchronization, merge-conflict resolution,
and multi-panel dashboard rendering. `make check` also runs startup/help smoke
checks and Git whitespace validation. CI runs both `make check` and
`make format-check`.

## License

MIT
