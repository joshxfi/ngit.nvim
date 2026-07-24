# ngit.nvim

A fast, review-first Git interface for Neovim.

ngit opens a dedicated tab with changed files on the left and a lazy-loaded
unified diff on the right. It is designed for the loop that happens most often
while coding: inspect changes, move through hunks, and stage exactly what should
be committed.

## Highlights

- Staged, unstaged, untracked, renamed, deleted, and conflicted files.
- Unified diffs with native `diff` highlighting.
- File and hunk navigation without leaving Neovim.
- Whole-file and hunk staging/unstaging.
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
```

With lazy.nvim:

```lua
{
  "joshxfi/ngit",
  cmd = { "NGit", "NGitClose", "NGitRefresh" },
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

### Default mappings

All mappings are buffer-local.

| Key | Action |
| --- | --- |
| `q` | Close ngit |
| `r` | Refresh |
| `j` / `k` | Next/previous file in the file panel |
| `<CR>` | Focus the selected diff |
| `<Tab>` / `<S-Tab>` | Next/previous changed file |
| `]c` / `[c` | Next/previous hunk |
| `s` | Stage file or current hunk |
| `u` | Unstage file or current hunk |
| `X` | Discard tracked worktree changes after confirmation |
| `o` | Open selected file |
| `/` | Filter changed files |
| `<leader>e` / `<leader>d` | Focus files/diff |
| `?` | Show help |

## Configuration

Configuration is optional:

```lua
require("ngit").setup({
  context = 3,
  debounce_ms = 45,
  refresh_debounce_ms = 120,
  max_diff_bytes = 2 * 1024 * 1024,
  cache_entries = 24,
  file_panel_width = 0.32,
  file_panel_height = 0.35,
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
    next_file = "<Tab>",
    prev_file = "<S-Tab>",
    next_hunk = "]c",
    prev_hunk = "[c",
    stage = "s",
    unstage = "u",
    discard = "X",
    open_file = "o",
    focus_files = "<leader>e",
    focus_preview = "<leader>d",
    filter = "/",
    help = "?",
  },
})
```

Set any mapping to `false` to disable it. Configuration is validated when
`setup()` is called.

## Commands

- `:NGit [directory]` — open or focus ngit.
- `:NGitRefresh` — refresh the active view.
- `:NGitClose` — close the active view and restore the previous tab.
- `:checkhealth ngit` — check Neovim, Git, and configuration.

## Safety

Read operations run with `GIT_OPTIONAL_LOCKS=0`. Commands use argument arrays
and literal pathspecs rather than a shell. Discard is limited to tracked
worktree changes and asks for confirmation by default; ngit never deletes
untracked files.

## Performance

The status screen is produced from one porcelain-v2 Git command. File diffs are
loaded only after selection, rapid selections are debounced, superseded jobs
are terminated, and cached patches are bounded by `cache_entries`. Large
previews are truncated at `max_diff_bytes`.

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
cover parsing, caching, diff extraction, file staging, hunk staging, unstaging,
and session rendering.

## License

MIT
