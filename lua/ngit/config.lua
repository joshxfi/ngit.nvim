local M = {}

---@class NgitConfig
---@field context integer Number of context lines in generated diffs.
---@field debounce_ms integer Delay before loading a newly selected diff.
---@field refresh_debounce_ms integer Delay used to coalesce repository refreshes.
---@field max_diff_bytes integer Soft limit for a preview before it is truncated.
---@field cache_entries integer Maximum number of cached file diffs.
---@field max_cache_bytes integer Maximum estimated memory retained by cached previews.
---@field commit_limit integer Number of commits loaded per page.
---@field layout "dashboard"|"vertical"|"stacked"|"auto" Main pane layout.
---@field file_panel_width number|integer Fraction or absolute width of the file panel.
---@field file_panel_height number|integer Retained compatibility option.
---@field diff_layout "auto"|"side_by_side"|"unified" Diff preview arrangement.
---@field side_by_side_min_width integer Minimum preview width for auto split mode.
---@field hide_statusline boolean Hide statusline plugin content in ngit windows.
---@field auto_refresh boolean Refresh an open view after relevant editor events.
---@field confirm_discard boolean Ask before destructive actions.
---@field signs table<string, string>
---@field mappings table<string, string|false>

---@type NgitConfig
local defaults = {
  context = 3,
  debounce_ms = 45,
  refresh_debounce_ms = 120,
  max_diff_bytes = 2 * 1024 * 1024,
  cache_entries = 24,
  max_cache_bytes = 32 * 1024 * 1024,
  commit_limit = 150,
  layout = "dashboard",
  file_panel_width = 0.32,
  file_panel_height = 0.35,
  diff_layout = "auto",
  side_by_side_min_width = 80,
  hide_statusline = true,
  auto_refresh = true,
  confirm_discard = true,
  ignore_whitespace = false,
  signs = {
    staged = "●",
    unstaged = "○",
    untracked = "?",
    conflict = "!",
    renamed = "→",
    deleted = "×",
    range = "◆",
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
    stage_all = "a",
    unstage_all = "A",
    discard = "X",
    open_file = "o",
    focus_files = "<leader>e",
    focus_preview = "0",
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
    choose_both = "cb",
    next_conflict = "]x",
    prev_conflict = "[x",
    continue_operation = "gC",
    abort_operation = "gA",
    merge = "m",
    rebase = "R",
    cherry_pick = "v",
    revert = "gv",
    reset = "gR",
    checkout_commit = "gx",
    tag = "t",
    rename_item = "gn",
    set_upstream = "gu",
    interactive_rebase = "gi",
    remote_menu = "gm",
    stash_menu = "gS",
    commit_menu = "gc",
    file_menu = "gf",
    copy_menu = "Y",
    review = "gr",
    blame = "gB",
    file_history = "gh",
    repos_menu = "gw",
    toggle_whitespace = "dw",
    increase_context = "d+",
    decrease_context = "d-",
  },
}

local config = vim.deepcopy(defaults)

local function reject_unknown(name, provided, known)
  for key in pairs(provided or {}) do
    if known[key] == nil then
      error(("ngit: unknown %s option %q"):format(name, key), 3)
    end
  end
end

-- Checked in order so a table with several mistakes always reports the same
-- one. vim.validate is deliberately not used: its (name, value, type) form
-- arrived in 0.11, and the table form it replaced is deprecated, so neither
-- spans the versions this plugin supports.
local option_types = {
  { "context", "number" },
  { "debounce_ms", "number" },
  { "refresh_debounce_ms", "number" },
  { "max_diff_bytes", "number" },
  { "cache_entries", "number" },
  { "max_cache_bytes", "number" },
  { "commit_limit", "number" },
  { "layout", "string" },
  { "file_panel_width", "number" },
  { "file_panel_height", "number" },
  { "diff_layout", "string" },
  { "side_by_side_min_width", "number" },
  { "hide_statusline", "boolean" },
  { "auto_refresh", "boolean" },
  { "confirm_discard", "boolean" },
  { "ignore_whitespace", "boolean" },
  { "signs", "table" },
  { "mappings", "table" },
}

local function validate(opts)
  reject_unknown("configuration", opts, defaults)
  reject_unknown("signs", opts.signs, defaults.signs)
  reject_unknown("mapping", opts.mappings, defaults.mappings)
  for _, option in ipairs(option_types) do
    local name, expected = option[1], option[2]
    local actual = type(opts[name])
    if actual ~= expected then
      error(("ngit: %s must be a %s, got %s"):format(name, expected, actual), 3)
    end
  end

  if opts.context < 0 or opts.context % 1 ~= 0 then
    error("ngit: context must be a non-negative integer", 3)
  end
  if opts.debounce_ms < 0 or opts.refresh_debounce_ms < 0 then
    error("ngit: debounce durations must be non-negative", 3)
  end
  if opts.max_diff_bytes < 1024 then
    error("ngit: max_diff_bytes must be at least 1024", 3)
  end
  if opts.cache_entries < 1 or opts.cache_entries % 1 ~= 0 then
    error("ngit: cache_entries must be a positive integer", 3)
  end
  if opts.max_cache_bytes < 1024 or opts.max_cache_bytes % 1 ~= 0 then
    error("ngit: max_cache_bytes must be an integer of at least 1024", 3)
  end
  if opts.commit_limit < 1 or opts.commit_limit % 1 ~= 0 then
    error("ngit: commit_limit must be a positive integer", 3)
  end
  if
    opts.layout ~= "dashboard"
    and opts.layout ~= "vertical"
    and opts.layout ~= "stacked"
    and opts.layout ~= "auto"
  then
    error("ngit: layout must be 'dashboard', 'vertical', 'stacked', or 'auto'", 3)
  end
  if opts.file_panel_width <= 0 or opts.file_panel_height <= 0 then
    error("ngit: panel dimensions must be positive", 3)
  end
  if
    opts.diff_layout ~= "auto"
    and opts.diff_layout ~= "side_by_side"
    and opts.diff_layout ~= "unified"
  then
    error("ngit: diff_layout must be 'auto', 'side_by_side', or 'unified'", 3)
  end
  if opts.side_by_side_min_width < 40 or opts.side_by_side_min_width % 1 ~= 0 then
    error("ngit: side_by_side_min_width must be an integer of at least 40", 3)
  end
  for name, sign in pairs(opts.signs) do
    if type(sign) ~= "string" then
      error(("ngit: signs.%s must be a string, got %s"):format(name, type(sign)), 3)
    end
  end
  for name, mapping in pairs(opts.mappings) do
    if type(mapping) ~= "string" and mapping ~= false then
      error(("ngit: mapping %q must be a string or false"):format(name), 3)
    end
  end
end

---@param opts? table
---@return NgitConfig
function M.setup(opts)
  opts = opts or {}
  reject_unknown("configuration", opts, defaults)
  reject_unknown("signs", opts.signs, defaults.signs)
  reject_unknown("mapping", opts.mappings, defaults.mappings)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)
  validate(merged)
  -- The former orientation values remain accepted so existing setup tables do
  -- not fail during the dashboard migration. The dashboard always keeps its
  -- patch on the right; these values are compatibility aliases.
  if merged.layout ~= "dashboard" then
    merged.layout = "dashboard"
  end
  config = merged
  return config
end

---@return NgitConfig
function M.get()
  return config
end

---@return NgitConfig
function M.defaults()
  return vim.deepcopy(defaults)
end

return M
