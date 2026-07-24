local M = {}

---@class NgitConfig
---@field context integer Number of context lines in generated diffs.
---@field debounce_ms integer Delay before loading a newly selected diff.
---@field refresh_debounce_ms integer Delay used to coalesce repository refreshes.
---@field max_diff_bytes integer Soft limit for a preview before it is truncated.
---@field cache_entries integer Maximum number of cached file diffs.
---@field file_panel_width number|integer Fraction or absolute width of the file panel.
---@field file_panel_height number|integer Fraction or absolute height in stacked layouts.
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
}

local config = vim.deepcopy(defaults)

local function reject_unknown(name, provided, known)
  for key in pairs(provided or {}) do
    if known[key] == nil then
      error(("ngit: unknown %s option %q"):format(name, key), 3)
    end
  end
end

local function validate(opts)
  reject_unknown("configuration", opts, defaults)
  reject_unknown("signs", opts.signs, defaults.signs)
  reject_unknown("mapping", opts.mappings, defaults.mappings)
  vim.validate("context", opts.context, "number")
  vim.validate("debounce_ms", opts.debounce_ms, "number")
  vim.validate("refresh_debounce_ms", opts.refresh_debounce_ms, "number")
  vim.validate("max_diff_bytes", opts.max_diff_bytes, "number")
  vim.validate("cache_entries", opts.cache_entries, "number")
  vim.validate("file_panel_width", opts.file_panel_width, "number")
  vim.validate("file_panel_height", opts.file_panel_height, "number")
  vim.validate("auto_refresh", opts.auto_refresh, "boolean")
  vim.validate("confirm_discard", opts.confirm_discard, "boolean")
  vim.validate("signs", opts.signs, "table")
  vim.validate("mappings", opts.mappings, "table")

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
  if opts.file_panel_width <= 0 or opts.file_panel_height <= 0 then
    error("ngit: panel dimensions must be positive", 3)
  end
  for name, sign in pairs(opts.signs) do
    vim.validate("signs." .. name, sign, "string")
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
