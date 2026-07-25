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
- Guarded worktree discard.
- Asynchronous Git operations; the editor event loop is never blocked.
- Stale-request cancellation, debounced previews, and a bounded LRU cache.
- NUL-delimited porcelain-v2 parsing for unusual filenames.
- No runtime dependencies and no global mappings.

## Requirements

- Neovim 0.10 or newer
- Git

## Installation

With `vim.pack`:

```lua
vim.pack.add({ "https://github.com/joshxfi/ngit" })

vim.keymap.set("n", "<leader>ng", "<cmd>NGit<cr>", {
  desc = "Open ngit",
})
```

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
disabled when the preview was truncated.

Focus dashboard panels without closing ngit:

| Mapping | View |
| --- | --- |
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
| `X` | Discard tracked worktree changes after confirmation |
| `o` | Open selected file |
| `/` | Filter changed files |
| `<leader>e` / `<leader>d` | Focus files/diff |
| `?` | Show help |
| `x` | Switch branch, or copy a selected commit hash |
| `n` | Create a branch or stash |
| `a` / `p` | Apply/pop a stash |
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
  commit_limit = 150,
  layout = "dashboard",
  diff_layout = "auto",
  side_by_side_min_width = 80,
  file_panel_width = 0.32,
  file_panel_height = 0.35,
  hide_statusline = true,
  auto_refresh = true,
  confirm_discard = true,
  signs = {
    staged = "●",
    unstaged = "○",
    untracked = "?",
    conflict = "!",
    renamed = "→",
    deleted = "×",
  },
  mappings = {
    close = "q",
    refresh = "r",
    next_item = "j",
    prev_item = "k",
    select = "<CR>",
    next_panel = "<Tab>",
    prev_panel = "<S-Tab>",
    focus_status = "1",
    focus_branches = "2",
    focus_commits = "3",
    focus_stashes = "4",
    status_view = "gs",
    commit_view = "gl",
    branch_view = "gb",
    stash_view = "gz",
    next_file = false,
    prev_file = false,
    next_hunk = "]c",
    prev_hunk = "[c",
    next_diff_file = "]f",
    prev_diff_file = "[f",
    toggle_diff = "dv",
    stage = "s",
    unstage = "u",
    discard = "X",
    open_file = "o",
    focus_files = "<leader>e",
    focus_preview = "<leader>d",
    filter = "/",
    help = "?",
    primary_action = "x",
    new_item = "n",
    delete_item = "D",
    apply_item = "a",
    pop_item = "p",
    commit = "c",
    amend = "C",
    load_more = "L",
    fetch = "f",
    pull = "U",
    push = "P",
    choose_ours = "co",
    choose_theirs = "ct",
    continue_operation = "gC",
    abort_operation = "gA",
    merge = "m",
    rebase = "R",
    cherry_pick = "v",
  },
})
```

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

Set any mapping to `false` to disable it. Configuration is validated when
`setup()` is called.

## Commands

- `:NGit [directory]` — open or focus ngit.
- `:NGitRefresh` — refresh the active view.
- `:NGitClose` — close the active view and restore the previous tab.
- `:NGitLog` — open ngit and focus Commits.
- `:NGitBranches` — open ngit and focus Branches.
- `:NGitStashes` — open ngit and focus Stashes.
- `:checkhealth ngit` — check Neovim, Git, and configuration.

For contributors, `make check` runs the test suite, startup/help smoke checks,
and Git whitespace validation. `make format-check` verifies Lua formatting
when StyLua is installed, and CI runs both.

## Safety

Read operations run with `GIT_OPTIONAL_LOCKS=0`. Commands use argument arrays
and literal pathspecs rather than a shell. Discard is limited to tracked
worktree changes and asks for confirmation by default; ngit never deletes
untracked files.

Branch deletion uses Git's merged-only `-d` behavior. Pull is deliberately
fast-forward-only. ngit never force-pushes, and aborting an active Git operation
requires confirmation. Remote commands disable invisible terminal credential
prompts and show their complete progress in a cancellable console.

## Performance

The four dashboard collections load independently and asynchronously. File and
object patches are loaded only for the active selection; changing panel focus
does not reload collection data. Rapid selections are debounced, superseded
jobs are terminated, and cached patches are bounded by `cache_entries`. Large
previews are truncated at `max_diff_bytes`. Each raw patch is parsed once into
the presentation model; switching split/unified views does not invoke Git
again.

Run the included parser benchmark:

```sh
make benchmark
```

## Development

```sh
make test
make benchmark
```

Tests use temporary real Git repositories and a headless Neovim instance. They
cover parsing, caching, diff extraction, file and hunk staging, commits,
branches, stashes, local remote synchronization, merge-conflict resolution,
and multi-panel dashboard rendering.

## License

MIT
