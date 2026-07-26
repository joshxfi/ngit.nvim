# ngit.nvim

A fast, review-first Git interface for Neovim.

The name reads as **n-git**—Neovim Git—in the same spirit as `nvim`.

ngit opens a dedicated dashboard with changes, branches, recent commits, and
stashes in persistent panels on the left and a lazy-loaded structured diff on
the right. It is designed for the loop that happens most often while coding:
inspect changes, move through hunks, and stage exactly what should be committed
without losing repository context.

<img width="1614" height="948" alt="image" src="https://github.com/user-attachments/assets/fcdc439b-d930-4475-9481-ffbcbbfd56c6" />

## Highlights

- Persistent Changes, Branches, Commits, and Stashes panels beside a live diff.
- Side-by-side diffs with aligned old/new lines and a polished unified fallback.
- Full-line, intraline, and source syntax highlighting inside previews.
- File, hunk, and line staging — a visual selection stages exactly what it
  covers — rename-aware across both index slots.
- Confirmed discard that names its exact effect before running, at the same
  three scopes.
- Review mode: point the Changes panel at any revision range, or at what your
  branch adds over its upstream.
- Blame, file history that follows renames, and a log filter Git answers.
- Per-block conflict resolution with ours, theirs, or both.
- Interactive rebase with a plan editor, autosquash, revert, and reset.
- Commit, amend, and a menu for `--signoff`, `--no-verify`, `--fixup`, and more.
- Branches, tags, remotes, worktrees, and submodules, all from the dashboard.
- Streaming fetch, pull, and push, including `--force-with-lease` — never plain
  `--force`.
- Asynchronous throughout, with no runtime dependencies and no global mappings.

## Requirements

- Neovim 0.10 or newer
- Git

## Installation

With lazy.nvim:

```lua
{
  "joshxfi/ngit.nvim",
  cmd = { "NGit", "NGitLog", "NGitBranches", "NGitStashes", "NGitClose", "NGitRefresh" },
  keys = {
    { "<leader>ng", "<cmd>NGit<cr>", desc = "Open ngit" },
  },
  opts = {},
}
```

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/joshxfi/ngit.nvim" })

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

| Section   | Diff compares          | `X` discards to                       |
| --------- | ---------------------- | ------------------------------------- |
| Staged    | `HEAD` to index        | `HEAD`, index and worktree both       |
| Unstaged  | index to worktree      | the staged content                    |
| Untracked | empty file to worktree | deletes the file                      |
| Conflicts | index to worktree      | refused; use `co`/`ct`/`cb`, or abort |
| Range     | the two revisions      | refused; review mode is read-only     |

`s`, `u`, and `X` work at three scopes. From the file panel they act on the
whole file; from a hunk in the diff they act on that hunk; and in visual mode
they act on exactly what the selection covers — several files in the panel, or
individual added and removed lines in the diff, the way `git add -p` splits a
hunk. `a` and `A` stage or unstage everything.

Narrowing a patch is not just filtering. A patch applies old to new, so a row
you did not pick has to be rewritten rather than dropped: whichever side the
target already holds survives as context, and whichever it does not disappears.
Staging and unstaging the same selection therefore produce different patches.
Splitting a whole-file addition or deletion is refused rather than handed to Git,
and hunk actions are disabled when a preview was truncated or whitespace is
being ignored — in both cases the preview is a reading aid, not a faithful patch.

Renames occupy two index slots, so staging, unstaging, and discarding all act
on the old and new path together. A file with unsaved changes in a loaded
buffer is never overwritten.

Commit history is paginated; press `L` to load another page. Branch previews
diff the branch against `HEAD`, while the current branch previews its tip.
Tags appear in the Branches panel and report the commit they name, peeled
through the tag object.

### Reviewing

Press `gr`, or run `:NGitReview`, to point the Changes panel at a revision range
instead of the working tree. With no argument the range is what your branch adds
over its upstream — falling back to `origin/HEAD`, then to a local `main`,
`master`, `develop`, or `trunk` — always in the three-dot form, so the answer is
your work rather than everything that landed on the base meanwhile.

`gh` follows one file: the Commits panel narrows to `git log --follow` for that
path and each preview narrows with it. `gB` blames the file in a float, where
`<CR>` on a row reveals that commit, paging history forward until it is found.
`o` from the diff opens the file at the line you were reading.

The Commits filter also understands queries Git answers: `author:`, `grep:`,
`path:`, `since:`, `until:`, and `all:true`, with quoted values allowed. Anything
else stays an instant substring match over the rows already loaded.

### Rewriting

`gi` opens an interactive rebase plan — one row per commit, oldest first, with
`p` `r` `e` `s` `f` `d` setting the action, `J`/`K` reordering, and `<C-s>`
running it. A `reword` becomes a pick plus a `break`, so the rebase stops with
that commit at `HEAD` where `C` amends it and `gC` continues; ngit will not hand
a buffer to a subprocess to get a message in. `gi` also offers autosquash, and
`gc` creates the `fixup!`/`squash!` commits it folds in.

`gR` resets onto the selection, `gv` reverts a commit, and `gx` checks one out
with a detached `HEAD`. A rewritten branch pushes through `gm`, which offers
`--force-with-lease`; plain `--force` is not offered at all.

### Default mappings

All mappings are buffer-local. See `:help ngit-mappings` for the full list.

| Key                   | Action                                                 |
| --------------------- | ------------------------------------------------------ |
| `q` / `r`             | Close ngit / refresh                                   |
| `j` / `k`             | Next/previous item in the focused panel                |
| `<Tab>` / `<S-Tab>`   | Next/previous panel                                    |
| `1` `2` `3` `4`       | Focus Changes/Branches/Commits/Stashes                 |
| `gs` `gb` `gl` `gz`   | The same four panels, by name                          |
| `<CR>` / `0`          | Focus the selected diff                                |
| `<Esc>` / `<leader>e` | Return to the active panel                             |
| `]c` / `[c`           | Next/previous hunk                                     |
| `]f` / `[f`           | Next/previous changed file in a multi-file preview     |
| `]x` / `[x`           | Next/previous conflict block                           |
| `dv`                  | Toggle side-by-side/unified diff                       |
| `dw` / `d+` / `d-`    | Ignore whitespace / more / less context                |
| `s` / `u`             | Stage/unstage file, hunk, or visual selection          |
| `a` / `A`             | Stage/unstage everything (Changes panel)               |
| `X`                   | Discard file, hunk, or selection, after confirmation    |
| `o` / `/`             | Open at the reviewed line / filter the panel           |
| `c` / `C` / `gc`      | Commit / amend / commit options                        |
| `gf` / `gS`           | File options (untrack, rename, restore) / stash options |
| `x`                   | Check out branch or tag, or copy a commit hash          |
| `n` / `D`             | Create a branch or stash / delete or drop one          |
| `gn` / `gu` / `t`     | Rename a branch / set its upstream / create a tag      |
| `a` / `p`             | Apply/pop a stash (Stashes panel)                      |
| `L`                   | Load another page of commits                           |
| `f` / `U` / `P`       | Fetch, fast-forward pull, or push                      |
| `gm`                  | Remote options, including `--force-with-lease`          |
| `co` / `ct` / `cb`    | Resolve a conflict with ours/theirs/both                |
| `gC` / `gA`           | Continue/abort the active Git operation                |
| `m` / `R` / `v`       | Merge / rebase onto / cherry-pick the selection        |
| `gi`                  | Interactive rebase plan, or autosquash                 |
| `gv` / `gR` / `gx`    | Revert / reset onto / detach at the selection          |
| `gr` / `gh` / `gB`    | Review a range / follow a file / blame                 |
| `Y` / `gw`            | Copy menu / worktrees and submodules                   |
| `?`                   | Show the key sheet                                     |

Actions reached through a menu are mapped and listed under `?`, but kept out of
the one-line footer, which has room only for the everyday keys.

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
  ignore_whitespace = false,
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
- `:NGitReview [range]` — review a range, or this branch against its upstream.
- `:NGitBlame [file]` — blame a file, or the current buffer.
- `:NGitHistory [file]` — follow a file's history across renames.
- `:checkhealth ngit` — check Neovim, Git, and configuration.

## Safety

Read operations run with `GIT_OPTIONAL_LOCKS=0`, and commands use argument
arrays and literal pathspecs rather than a shell. Discards are confirmed and
never overwrite a file with unsaved changes in a loaded buffer.

Branch deletion asks Git first and only offers the forced form once Git has
called the branch unmerged, naming what would be lost. The default pull is
fast-forward-only. The only forcing push offered is `--force-with-lease`, which
refuses when the remote moved since your last fetch; plain `--force` is not
exposed. Review mode is read-only by construction — a revision range has no index
side, so staging there is refused rather than passed to Git. Resolving conflicts
one block at a time stages the file only once no markers remain, so a partly
resolved file is never marked resolved.

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

| Workload                     |                    Fixture |  Median |
| ---------------------------- | -------------------------: | ------: |
| Porcelain-v2 status parser   |               10,000 files |  6.4 ms |
| Commit parser                |             10,000 commits | 18.0 ms |
| Branch parser                |                10,000 refs | 11.7 ms |
| Diff presentation            | 4 KiB near-identical lines | 0.37 ms |
| Diff presentation            |           4,000-line patch | 14.7 ms |
| Preview render, unified      |           4,000-line patch |  5.7 ms |
| Preview render, side by side |           4,000-line patch |  6.7 ms |

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
