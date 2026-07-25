# ngit.nvim

A fast, review-first Git interface for Neovim.

The name reads as **n-git**—Neovim Git—in the same spirit as `nvim`.

ngit opens a dedicated dashboard with changes, branches, recent commits, and
stashes in persistent panels on the left and a lazy-loaded structured diff on
the right. It is designed for the loop that happens most often while coding:
inspect changes, move through hunks, and stage exactly what should be committed
without losing repository context.

<!-- A short demo recording belongs here: the dashboard, hunk staging, and a
     commit. It is the highest-value addition left to this README. -->

## Highlights

- Persistent Changes, Branches, Commits, and Stashes panels beside a live diff.
- Side-by-side diffs with aligned old/new lines and a polished unified fallback.
- Full-line, intraline, and source syntax highlighting inside previews.
- Whole-file and hunk staging, rename-aware across both index slots.
- Confirmed discard that names its exact effect before running.
- Commit and amend in a `gitcommit` buffer; merge, rebase, cherry-pick, stashes.
- Streaming fetch, fast-forward pull, and push that offers `--set-upstream`.
- Asynchronous throughout, with no runtime dependencies and no global mappings.

## Requirements

- Neovim 0.10 or newer
- Git

## Installation

With lazy.nvim:

```lua
{
  "joshxfi/ngit",
  cmd = { "NGit", "NGitLog", "NGitBranches", "NGitStashes", "NGitClose", "NGitRefresh" },
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

Run `:NGit` from any file in a Git repository, or `:NGit ~/code/project` for a
specific one. The recommended launcher is `<leader>ng`: `n` for Neovim, `g` for
Git. ngit creates no global mapping by default, so it cannot collide with your
existing leader keys.

`<Tab>` and `<S-Tab>` cycle panels, `1`–`4` jump straight to one, `j` and `k`
move within the focused panel, and `<CR>` focuses the preview. `<Esc>` returns.
Press `?` for the full key sheet at any time.

### Staging and discarding

The section a file is selected in decides what the diff compares and what the
actions do:

| Section | Diff compares | `X` discards to |
| --- | --- | --- |
| Staged | `HEAD` to index | `HEAD`, index and worktree both |
| Unstaged | index to worktree | the staged content |
| Untracked | empty file to worktree | deletes the file |
| Conflicts | index to worktree | refused; use `co`/`ct`, or abort |

From the file panel, `s` and `u` act on the whole file. From a hunk in the diff
panel, they act on that hunk alone. `a` and `A` stage or unstage everything.
Hunk actions are deliberately disabled when a preview was truncated.

Renames occupy two index slots, so staging, unstaging, and discarding all act
on the old and new path together. A file with unsaved changes in a loaded
buffer is never overwritten.

Commit history is paginated; press `L` to load another page. Branch previews
diff the branch against `HEAD`, while the current branch previews its tip.

### Default mappings

All mappings are buffer-local. See `:help ngit-mappings` for the full list.

| Key | Action |
| --- | --- |
| `q` / `r` | Close ngit / refresh |
| `j` / `k` | Next/previous item in the focused panel |
| `<Tab>` / `<S-Tab>` | Next/previous panel |
| `1` `2` `3` `4` | Focus Changes/Branches/Commits/Stashes |
| `gs` `gb` `gl` `gz` | The same four panels, by name |
| `<CR>` / `0` | Focus the selected diff |
| `<Esc>` / `<leader>e` | Return to the active panel |
| `]c` / `[c` | Next/previous hunk |
| `]f` / `[f` | Next/previous changed file in a multi-file preview |
| `dv` | Toggle side-by-side/unified diff |
| `s` / `u` | Stage/unstage file or current hunk |
| `a` / `A` | Stage/unstage everything (Changes panel) |
| `X` | Discard the selected change, after confirmation |
| `o` / `/` | Open selected file / filter the panel |
| `c` / `C` | Create/amend a commit in a `gitcommit` buffer |
| `x` | Switch branch, or copy a selected commit hash |
| `n` / `D` | Create a branch or stash / delete or drop one |
| `a` / `p` | Apply/pop a stash (Stashes panel) |
| `L` | Load another page of commits |
| `f` / `U` / `P` | Fetch, fast-forward pull, or push |
| `co` / `ct` | Resolve a conflict with ours/theirs and stage it |
| `gC` / `gA` | Continue/abort the active Git operation |
| `m` / `R` / `v` | Merge / rebase onto / cherry-pick the selection |
| `?` | Show the key sheet |

## Configuration

Configuration is optional; defaults work without calling `setup()`. Every
option is documented in `:help ngit-configure`.

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

`diff_layout` accepts `"auto"`, `"side_by_side"`, or `"unified"`. Auto uses
aligned old/new panes once the preview reaches `side_by_side_min_width` columns
and switches to unified below that. Diff colors are derived from your theme and
recomputed after `:colorscheme`; see `:help ngit-highlights` to override them.

## Commands

- `:NGit [directory]` — open or focus ngit.
- `:NGitRefresh` — refresh the active view.
- `:NGitClose` — close the active view and restore the previous tab.
- `:NGitLog` / `:NGitBranches` / `:NGitStashes` — open and focus that panel.
- `:checkhealth ngit` — check Neovim, Git, and configuration.

## Safety

Read operations run with `GIT_OPTIONAL_LOCKS=0`, and commands use argument
arrays and literal pathspecs rather than a shell. Discards are confirmed and
never overwrite a file with unsaved changes in a loaded buffer. Branch deletion
is merged-only, pull is fast-forward-only, and ngit never force-pushes.
Failures report what Git actually said, including the refusals it prints on
standard output. See `:help ngit-safety`.

## Performance

The four collections load independently and asynchronously; patches are fetched
only for the active selection. Rapid selections are debounced, superseded jobs
are terminated, and previews are cached under both `cache_entries` and
`max_cache_bytes`. Source line numbers are drawn through `'statuscolumn'`, so a
patch costs nothing for rows that are never displayed.

`make benchmark` runs a deterministic microbenchmark using generated fixtures,
warm-up runs, and the median of seven timed samples. On an Apple M4 with 24 GB
RAM, Neovim 0.12.4:

| Workload | Fixture | Median |
| --- | ---: | ---: |
| Porcelain-v2 status parser | 10,000 files | 6.4 ms |
| Commit parser | 10,000 commits | 18.0 ms |
| Branch parser | 10,000 refs | 11.7 ms |
| Diff presentation | 4 KiB near-identical lines | 0.37 ms |
| Diff presentation | 4,000-line patch | 14.7 ms |
| Preview render, unified | 4,000-line patch | 5.7 ms |
| Preview render, side by side | 4,000-line patch | 6.7 ms |

The parser rows measure in-process work, not Git startup or disk I/O. The
render rows include drawing: buffer population, highlight extmarks, and the
source-number gutter, which is the cost paid on every selection change. Treat
these as regression reference points rather than guarantees.

## Development

```sh
make check
make format-check
make benchmark
```

Tests use temporary real Git repositories and a headless Neovim instance,
covering parsing, caching, diff extraction, file and hunk staging, commits,
branches, stashes, local remote synchronization, merge-conflict resolution, and
multi-panel dashboard rendering. `make check` also runs startup/help smoke
checks and Git whitespace validation. CI runs `make check` and
`make format-check`.

## License

MIT
