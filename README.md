# ngit.nvim

A Git interface for Neovim built around reviewing and staging changes.

The name reads as n-git, for Neovim Git, the same way `nvim` reads as Neovim.

ngit opens a dashboard in its own tab. Changes, Branches, Commits, and Stashes
panels stay open on the left, and the right side shows the diff of the selected
entry, loaded only when you select it. The layout fits the work you repeat most
while coding. You read your changes, move from hunk to hunk, and stage exactly
what belongs in the commit, with your branches and history still on screen.

<img width="1614" height="948" alt="image" src="https://github.com/user-attachments/assets/fcdc439b-d930-4475-9481-ffbcbbfd56c6" />

## Highlights

- Changes, Branches, Commits, and Stashes panels that stay open beside the diff.
- Side-by-side diffs with old and new lines aligned, and a unified layout for
  narrow windows.
- Line, intraline, and source syntax highlighting inside the diff.
- Staging by file, hunk, or line. A visual selection stages exactly what it
  covers, and renames stage both their old and new path.
- Discard at the same three scopes, after a confirmation that says exactly what
  will change.
- Review mode, which shows any revision range in the Changes panel, or what
  your branch adds over its upstream.
- Blame, file history that follows renames, and a Commits filter that passes
  `author:`, `grep:`, and `path:` queries to Git.
- Conflict resolution one block at a time, taking ours, theirs, or both.
- Interactive rebase with a plan editor, plus autosquash, revert, and reset.
- Commit and amend, with a menu for `--signoff`, `--no-verify`, `--fixup`, and
  more.
- Branches, tags, remotes, worktrees, and submodules, all from the dashboard.
- Fetch, pull, and push with streamed output. The only forced push is
  `--force-with-lease`, never plain `--force`.
- Every Git call runs in the background. ngit has no runtime dependencies and
  adds no global mappings.

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

Run `:NGit` from any file in a Git repository, or `:NGit ~/code/project` to
open a specific one. The examples above map it to `<leader>ng`, with `n` for
Neovim and `g` for Git. ngit creates no global mappings itself, so it never
collides with your leader keys.

`<Tab>` and `<S-Tab>` cycle through the panels, and `1` to `4` jump straight to
one. `j` and `k` move within the focused panel, `<CR>` focuses the diff, and
`<Esc>` returns to the panel. Press `?` at any time for the full key sheet.

### Staging and discarding

The section a file is listed in decides what the diff compares and what the
actions do.

| Section   | Diff compares          | `X` discards to                       |
| --------- | ---------------------- | ------------------------------------- |
| Staged    | `HEAD` to index        | `HEAD`, index and worktree both       |
| Unstaged  | index to worktree      | the staged content                    |
| Untracked | empty file to worktree | deletes the file                      |
| Conflicts | our side to worktree   | refused; use `co`/`ct`/`cb`, or abort |
| Range     | the two revisions      | refused; review mode is read-only     |

`s`, `u`, and `X` work at three scopes. From the file panel they act on the
whole file, and from a hunk in the diff they act on that hunk. In visual mode
they act on exactly what the selection covers. In the panel that can be several
files. In the diff it can be single added and removed lines, the way
`git add -p` splits a hunk. `a` and `A` stage or unstage everything.

When you stage part of a hunk, ngit rewrites the rows you did not pick instead
of dropping them. A patch turns the old side into the new one, so an unpicked
row stays as context if the target already has it and is left out if it does
not. Staging and unstaging the same selection therefore produce different
patches.

ngit refuses to split a whole-file addition or deletion. It also disables hunk
actions when a preview was truncated or whitespace changes are hidden, because
in both cases the diff on screen no longer matches the real patch.

A rename takes up two index slots, so staging, unstaging, and discarding act on
the old and new path together. ngit never overwrites a file that has unsaved
changes in an open buffer.

The Commits panel loads history a page at a time. Press `L` to load the next
page. A branch preview diffs that branch against `HEAD`, and the current branch
previews its latest commit. Tags appear in the Branches panel, and an annotated
tag previews the commit it points to.

### Reviewing

Press `gr`, or run `:NGitReview`, to show a revision range in the Changes panel
instead of the working tree. With no argument, the range is what your branch
adds over its upstream. If the branch has no upstream, ngit tries
`origin/HEAD`, then a local `main`, `master`, `develop`, or `trunk`. It always
uses the three-dot form, so you see your own commits and not everything that
landed on the base since you branched.

`gh` follows one file. The Commits panel narrows to `git log --follow` for that
path, and each preview shows only that file. `gB` blames the file in a floating
window, and `<CR>` on a row shows that commit, loading more history until it
finds it. `o` in the diff opens the file at the line under the cursor.

The Commits filter passes these queries to Git: `author:`, `grep:`, `path:`,
`since:`, `until:`, and `all:true`. Values can be quoted. Any other text
filters the loaded rows by substring as you type.

### Rewriting

`gi` opens an interactive rebase plan with one row per commit, oldest first.
`p` `r` `e` `s` `f` `d` set a row's action, `J` and `K` move it, and `<C-s>`
runs the plan. ngit turns a `reword` into a pick followed by a `break`, so the
rebase stops with that commit at `HEAD`. Amend it with `C`, then continue with
`gC`. This way ngit never has to give a Git subprocess a buffer to collect a
message from. `gi` also offers autosquash, and `gc` creates the `fixup!` and
`squash!` commits it folds in.

`gR` resets onto the selected commit, `gv` reverts it, and `gx` checks it out
with a detached `HEAD`. Push a rewritten branch through `gm`, which offers
`--force-with-lease`. ngit never offers plain `--force`.

### Default mappings

All mappings are buffer-local. See `:help ngit-mappings` for the full list.

| Key                   | Action                                                  |
| --------------------- | ------------------------------------------------------- |
| `q` / `r`             | Close ngit / refresh                                    |
| `j` / `k`             | Next/previous item in the focused panel                 |
| `<Tab>` / `<S-Tab>`   | Next/previous panel                                     |
| `1` `2` `3` `4`       | Focus Changes/Branches/Commits/Stashes                  |
| `gs` `gb` `gl` `gz`   | The same four panels, by name                           |
| `<CR>` / `0`          | Focus the selected diff                                 |
| `<Esc>` / `<leader>e` | Return to the active panel                              |
| `]c` / `[c`           | Next/previous hunk                                      |
| `]f` / `[f`           | Next/previous changed file in a multi-file preview      |
| `]x` / `[x`           | Next/previous conflict block                            |
| `dv`                  | Toggle side-by-side/unified diff                        |
| `dw` / `d+` / `d-`    | Ignore whitespace / more / less context                 |
| `s` / `u`             | Stage/unstage file, hunk, or visual selection           |
| `a` / `A`             | Stage/unstage everything (Changes panel)                |
| `X`                   | Discard file, hunk, or selection, after confirmation    |
| `o` / `/`             | Open at the reviewed line / filter the panel            |
| `c` / `C` / `gc`      | Commit / amend / commit options                         |
| `gf` / `gS`           | File options (untrack, rename, restore) / stash options |
| `x`                   | Check out branch or tag, or copy a commit hash          |
| `n` / `D`             | Create a branch or stash / delete or drop one           |
| `gn` / `gu` / `t`     | Rename a branch / set its upstream / create a tag       |
| `a` / `p`             | Apply/pop a stash (Stashes panel)                       |
| `L`                   | Load another page of commits                            |
| `f` / `U` / `P`       | Fetch, fast-forward pull, or push                       |
| `gm`                  | Remote options, including `--force-with-lease`          |
| `co` / `ct` / `cb`    | Resolve a conflict with ours/theirs/both                |
| `gC` / `gA`           | Continue/abort the active Git operation                 |
| `m` / `R` / `v`       | Merge / rebase onto / cherry-pick the selection         |
| `gi`                  | Interactive rebase plan, or autosquash                  |
| `gv` / `gR` / `gx`    | Revert / reset onto / detach at the selection           |
| `gr` / `gh` / `gB`    | Review a range / follow a file / blame                  |
| `Y` / `gw`            | Copy menu / worktrees and submodules                    |
| `?`                   | Show the key sheet                                      |

Actions you reach through a menu also have their own mappings, listed under
`?`. The one-line footer leaves them out because it only has room for the
everyday keys.

## Configuration

Calling `setup()` is optional, and the defaults work without it.
`:help ngit-configure` documents every option.

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
  side_by_side_min_width = 130,
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

`diff_layout` accepts `"auto"`, `"side_by_side"`, or `"unified"`. With
`"auto"`, the diff is side by side while the preview is at least
`side_by_side_min_width` columns wide, which leaves about 60 columns of code
per side, and unified below that. ngit re-checks the width whenever the
terminal or one of ngit's own windows changes size, and keeps the cursor on the
line you were reading when the layout switches. The right edge of the preview
header shows the current layout and whether `auto` or `dv` chose it. A layout
picked with `dv` stays until the preview width crosses the threshold, and then
`auto` decides again.

ngit derives the diff colors from your theme and recomputes them after
`:colorscheme`. See `:help ngit-highlights` to override them.

## Commands

- `:NGit [directory]` opens or focuses ngit.
- `:NGitRefresh` refreshes the active view.
- `:NGitClose` closes the active view and returns to the previous tab.
- `:NGitLog`, `:NGitBranches`, and `:NGitStashes` open ngit and focus that
  panel.
- `:NGitReview [range]` reviews a range, or this branch against its upstream.
- `:NGitBlame [file]` blames a file, or the current buffer.
- `:NGitHistory [file]` follows a file's history across renames.
- `:checkhealth ngit` checks Neovim, Git, and your configuration.

## Safety

ngit runs its read-only Git commands with `GIT_OPTIONAL_LOCKS=0`, so they never
take the index lock your own Git commands need. It passes arguments to Git as
an array with literal pathspecs and never through a shell, so a file name is
never read as shell syntax or a glob.

ngit asks before discards, hard resets, and restores, and none of them
overwrites a file with unsaved changes in an open buffer. Before a switch,
merge, rebase, cherry-pick, revert, stash apply, or pull, ngit offers to save
such buffers. Git then sees the edits as uncommitted changes and refuses to
overwrite them, as it would for any other uncommitted change.

To delete a branch, ngit first asks Git for a normal delete. It offers the
forced delete only after Git reports the branch as unmerged, and says what
would be lost. The default pull is fast-forward only. The only forced push ngit
offers is `--force-with-lease`, which refuses if the remote moved since your
last fetch.

Review mode is read-only because a revision range has no index side. ngit
refuses to stage there instead of passing the request to Git. When you resolve
conflicts one block at a time, ngit stages the file only after the last marker
is gone, so a partly resolved file is never marked resolved.

When a command fails, ngit shows Git's own message, including refusals that Git
prints on standard output. See `:help ngit-safety`.

## Performance

The four panels load independently in the background, and ngit fetches a patch
only for the selected entry. It waits for rapid selection changes to settle,
stops jobs that a newer selection replaced, and caches previews within both
`cache_entries` and `max_cache_bytes`. Line numbers are drawn through
`'statuscolumn'`, so rows that never reach the screen cost nothing.

`make benchmark` runs a repeatable microbenchmark on generated fixtures. It
runs each workload a few times to warm up, then reports the median of seven
timed runs. On an Apple M4 with 24 GB RAM and Neovim 0.12.4:

| Workload                     |                    Fixture |  Median |
| ---------------------------- | -------------------------: | ------: |
| Porcelain-v2 status parser   |               10,000 files |  6.9 ms |
| Commit parser                |             10,000 commits | 19.3 ms |
| Branch parser                |                10,000 refs | 14.5 ms |
| Diff presentation            | 4 KiB near-identical lines | 0.39 ms |
| Diff presentation            |           4,000-line patch | 17.0 ms |
| Preview render, unified      |           4,000-line patch |  4.6 ms |
| Preview render, side by side |           4,000-line patch |  5.1 ms |

The parser rows measure work inside Neovim, not Git startup or disk I/O. The
render rows include filling the buffer, placing highlight extmarks, and drawing
the line-number gutter, which together are the cost of every selection change.
Use these numbers to catch regressions, not as guarantees.

## Development

```sh
make check
make format-check
make benchmark
```

The tests run a headless Neovim against temporary, real Git repositories. They
cover parsing, caching, diff extraction, file and hunk staging, commits,
branches, stashes, syncing with a local remote, merge-conflict resolution, and
dashboard rendering. `make check` also confirms that the plugin loads and the
help file builds, and runs `git diff --check`. CI runs `make check` and
`make format-check`.

## License

MIT
