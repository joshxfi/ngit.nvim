local config_module = require("ngit.config")
local diff_backend = require("ngit.git.diff")
local mutate = require("ngit.git.mutate")
local status_backend = require("ngit.git.status")
local Lru = require("ngit.util.lru")

local Session = {}
Session.__index = Session

local namespace = vim.api.nvim_create_namespace("ngit")
local next_id = 0

local section_order = { "conflict", "staged", "unstaged", "untracked" }
local section_titles = {
  conflict = "Conflicts",
  staged = "Staged",
  unstaged = "Unstaged",
  untracked = "Untracked",
}
local section_highlights = {
  conflict = "NgitConflict",
  staged = "NgitStaged",
  unstaged = "NgitUnstaged",
  untracked = "NgitUntracked",
}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function valid_tab(tab)
  return tab and vim.api.nvim_tabpage_is_valid(tab)
end

local function scratch_buffer(name, filetype)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, ("ngit://%s/%s"):format(next_id, name))
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
  return buffer
end

local function set_lines(buffer, lines)
  if not valid_buffer(buffer) then
    return
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
end

local function status_present(value)
  return value ~= "." and value ~= " " and value ~= "?"
end

local function display_entries(status, filter)
  local groups = { conflict = {}, staged = {}, unstaged = {}, untracked = {} }
  local needle = filter and filter:lower() or nil

  for _, file in ipairs(status.files) do
    local matches = not needle or needle == "" or file.path:lower():find(needle, 1, true)
    if matches then
      if file.kind == "conflict" then
        groups.conflict[#groups.conflict + 1] = { section = "conflict", file = file }
      elseif file.kind == "untracked" then
        groups.untracked[#groups.untracked + 1] = { section = "untracked", file = file }
      else
        if status_present(file.index_status) then
          groups.staged[#groups.staged + 1] = { section = "staged", file = file }
        end
        if status_present(file.worktree_status) then
          groups.unstaged[#groups.unstaged + 1] = { section = "unstaged", file = file }
        end
      end
    end
  end
  return groups
end

local function entry_key(entry)
  return entry and (entry.section .. "\0" .. entry.file.path) or nil
end

local function sign_for(config, entry)
  if entry.section == "conflict" then
    return config.signs.conflict
  elseif entry.section == "untracked" then
    return config.signs.untracked
  elseif entry.file.kind == "renamed" then
    return config.signs.renamed
  elseif entry.file.kind == "deleted" then
    return config.signs.deleted
  end
  return config.signs[entry.section]
end

local function display_path(entry)
  local function sanitize(path)
    return path:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
  end
  if entry.file.old_path then
    return ("%s → %s"):format(sanitize(entry.file.old_path), sanitize(entry.file.path))
  end
  return sanitize(entry.file.path)
end

local function statusline_escape(value)
  return value:gsub("%%", "%%%%"):gsub("[\r\n]", " ")
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit" })
end

---@param root string
function Session.new(root)
  next_id = next_id + 1
  local self = setmetatable({
    id = next_id,
    root = root,
    config = config_module.get(),
    status = nil,
    entries = {},
    row_entries = {},
    selected = 1,
    filter = nil,
    generation = 0,
    status_request = 0,
    diff_request = 0,
    diff_job = nil,
    status_job = nil,
    current_diff = nil,
    closed = false,
    cache = nil,
  }, Session)
  self.cache = Lru.new(self.config.cache_entries)
  return self
end

function Session:open()
  self.origin_tab = vim.api.nvim_get_current_tabpage()
  self.origin_win = vim.api.nvim_get_current_win()

  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  self.files_win = vim.api.nvim_get_current_win()
  self.files_buf = scratch_buffer("files", "ngit")
  vim.api.nvim_win_set_buf(self.files_win, self.files_buf)

  self.layout = vim.o.columns >= 100 and "vertical" or "stacked"
  if self.layout == "vertical" then
    vim.cmd("botright vsplit")
  else
    vim.cmd("botright split")
  end
  self.preview_win = vim.api.nvim_get_current_win()
  self.preview_buf = scratch_buffer("diff", "diff")
  vim.api.nvim_win_set_buf(self.preview_win, self.preview_buf)

  if self.layout == "vertical" then
    local columns = vim.o.columns
    local configured = self.config.file_panel_width
    local width = configured < 1 and math.floor(columns * configured) or math.floor(configured)
    width = math.max(28, math.min(width, math.max(28, columns - 40)))
    vim.api.nvim_win_set_width(self.files_win, width)
    vim.wo[self.files_win].winfixwidth = true
  else
    local lines = vim.o.lines
    local configured = self.config.file_panel_height
    local height = configured < 1 and math.floor(lines * configured) or math.floor(configured)
    height = math.max(6, math.min(height, math.max(6, lines - 10)))
    vim.api.nvim_win_set_height(self.files_win, height)
    vim.wo[self.files_win].winfixheight = true
  end

  vim.wo[self.files_win].number = false
  vim.wo[self.files_win].relativenumber = false
  vim.wo[self.files_win].signcolumn = "no"
  vim.wo[self.files_win].cursorline = true
  vim.wo[self.files_win].wrap = false
  vim.wo[self.files_win].winbar = "%#NgitHeader# ngit "

  vim.wo[self.preview_win].number = true
  vim.wo[self.preview_win].relativenumber = false
  vim.wo[self.preview_win].signcolumn = "no"
  vim.wo[self.preview_win].wrap = false
  vim.wo[self.preview_win].winbar = "%#NgitMuted# Select a file "

  self:install_mappings()
  self:install_autocommands()
  set_lines(self.files_buf, { "", "  Loading repository status…" })
  set_lines(self.preview_buf, { "", "  Select a changed file to preview its diff." })
  vim.api.nvim_set_current_win(self.files_win)
  self:refresh()
end

function Session:install_mappings()
  local mappings = self.config.mappings
  local function map(key, callback, description, buffers)
    if not key or key == false or key == "" then
      return
    end
    for _, buffer in ipairs(buffers or { self.files_buf, self.preview_buf }) do
      vim.keymap.set("n", key, callback, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "ngit: " .. description,
      })
    end
  end

  map(mappings.close, function()
    self:close()
  end, "close")
  map(mappings.refresh, function()
    self:refresh()
  end, "refresh")
  map(mappings.next_item, function()
    self:select_relative(1)
  end, "next changed file", { self.files_buf })
  map(mappings.prev_item, function()
    self:select_relative(-1)
  end, "previous changed file", { self.files_buf })
  map(mappings.select, function()
    if valid_window(self.preview_win) then
      vim.api.nvim_set_current_win(self.preview_win)
    end
  end, "focus selected diff", { self.files_buf })
  map(mappings.next_file, function()
    self:select_relative(1)
  end, "next file")
  map(mappings.prev_file, function()
    self:select_relative(-1)
  end, "previous file")
  map(mappings.next_hunk, function()
    self:jump_hunk(1)
  end, "next hunk")
  map(mappings.prev_hunk, function()
    self:jump_hunk(-1)
  end, "previous hunk")
  map(mappings.stage, function()
    self:stage()
  end, "stage")
  map(mappings.unstage, function()
    self:unstage()
  end, "unstage")
  map(mappings.discard, function()
    self:discard()
  end, "discard worktree changes")
  map(mappings.open_file, function()
    self:open_file()
  end, "open file")
  map(mappings.focus_files, function()
    if valid_window(self.files_win) then
      vim.api.nvim_set_current_win(self.files_win)
    end
  end, "focus files")
  map(mappings.focus_preview, function()
    if valid_window(self.preview_win) then
      vim.api.nvim_set_current_win(self.preview_win)
    end
  end, "focus preview")
  map(mappings.filter, function()
    self:prompt_filter()
  end, "filter files")
  map(mappings.help, function()
    self:show_help()
  end, "help")
end

function Session:install_autocommands()
  self.augroup = vim.api.nvim_create_augroup(("ngit_session_%d"):format(self.id), { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = self.augroup,
    buffer = self.files_buf,
    callback = function()
      if self.closed then
        return
      end
      local row = vim.api.nvim_win_get_cursor(self.files_win)[1]
      local entry = self.row_entries[row]
      if entry then
        self:select_entry(entry)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.files_buf,
    once = true,
    callback = function()
      self:dispose()
    end,
  })

  if self.config.auto_refresh then
    vim.api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "ShellCmdPost" }, {
      group = self.augroup,
      callback = function()
        self:schedule_refresh()
      end,
    })
  end
end

function Session:dispose()
  if self.closed then
    return
  end
  self.closed = true
  self.status_request = self.status_request + 1
  self.diff_request = self.diff_request + 1
  if self.diff_job then
    pcall(self.diff_job.kill, self.diff_job, 15)
    self.diff_job = nil
  end
  if self.status_job then
    pcall(self.status_job.kill, self.status_job, 15)
    self.status_job = nil
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if self.on_close then
    self.on_close(self)
  end
end

function Session:close()
  if self.closed then
    return
  end
  local tab = self.tab
  local origin = self.origin_tab
  self:dispose()
  if valid_tab(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose")
  end
  if valid_tab(origin) then
    vim.api.nvim_set_current_tabpage(origin)
  end
end

function Session:schedule_refresh()
  self.refresh_timer = (self.refresh_timer or 0) + 1
  local token = self.refresh_timer
  vim.defer_fn(function()
    if not self.closed and token == self.refresh_timer then
      self:refresh()
    end
  end, self.config.refresh_debounce_ms)
end

function Session:refresh()
  if self.closed then
    return
  end
  self.status_request = self.status_request + 1
  local request = self.status_request
  local selected_key = entry_key(self.entries[self.selected])
  if self.status_job then
    pcall(self.status_job.kill, self.status_job, 15)
    self.status_job = nil
  end

  self.status_job = status_backend.load(self.root, function(status, err)
    self.status_job = nil
    if self.closed or request ~= self.status_request then
      return
    end
    if not status then
      notify(err or "Unable to load Git status", vim.log.levels.ERROR)
      return
    end

    self.status = status
    self.generation = self.generation + 1
    self.cache:clear()
    self:render_files(selected_key)
    self:load_preview()
  end)
end

function Session:render_files(preferred_key)
  if not self.status or not valid_buffer(self.files_buf) then
    return
  end
  local groups = display_entries(self.status, self.filter)
  local lines = {}
  local row_entries = {}
  local entries = {}
  local section_rows = {}

  for _, section in ipairs(section_order) do
    local group = groups[section]
    if #group > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      lines[#lines + 1] = ("  %s (%d)"):format(section_titles[section], #group)
      section_rows[#section_rows + 1] = { row = #lines - 1, section = section }
      for _, entry in ipairs(group) do
        entries[#entries + 1] = entry
        lines[#lines + 1] = ("  %s %s"):format(sign_for(self.config, entry), display_path(entry))
        row_entries[#lines] = entry
        entry.row = #lines
        entry.index = #entries
      end
    end
  end

  if #entries == 0 then
    lines = {
      "",
      self.filter and "  No changes match the current filter." or "  Working tree clean.",
    }
  end

  self.entries = entries
  self.row_entries = row_entries
  self.selected = math.min(self.selected, math.max(1, #entries))
  if preferred_key then
    for index, entry in ipairs(entries) do
      if entry_key(entry) == preferred_key then
        self.selected = index
        break
      end
    end
  end

  set_lines(self.files_buf, lines)
  vim.api.nvim_buf_clear_namespace(self.files_buf, namespace, 0, -1)
  for _, item in ipairs(section_rows) do
    vim.api.nvim_buf_set_extmark(self.files_buf, namespace, item.row, 0, {
      end_col = 0,
      hl_group = section_highlights[item.section],
      hl_eol = true,
    })
  end

  local suffix = ""
  if self.status.ahead > 0 or self.status.behind > 0 then
    suffix = (" ↑%d ↓%d"):format(self.status.ahead, self.status.behind)
  end
  if self.filter and self.filter ~= "" then
    suffix = suffix .. (" · /%s"):format(self.filter)
  end
  vim.wo[self.files_win].winbar =
    ("%%#NgitHeader# ngit %%#NgitMuted#· %s%s "):format(
      statusline_escape(self.status.branch),
      statusline_escape(suffix)
    )

  self:update_file_cursor()
end

function Session:update_file_cursor()
  local entry = self.entries[self.selected]
  if entry and valid_window(self.files_win) then
    pcall(vim.api.nvim_win_set_cursor, self.files_win, { entry.row, 0 })
  end
end

function Session:select_entry(target)
  for index, entry in ipairs(self.entries) do
    if entry == target then
      if self.selected ~= index then
        self.selected = index
        self:load_preview()
      end
      return
    end
  end
end

function Session:select_relative(delta)
  if #self.entries == 0 then
    return
  end
  self.selected = ((self.selected - 1 + delta) % #self.entries) + 1
  self:update_file_cursor()
  self:load_preview()
end

function Session:cache_key(entry)
  return table.concat({
    tostring(self.generation),
    entry.section,
    entry.file.path,
    tostring(self.config.context),
  }, "\0")
end

function Session:load_preview()
  self.diff_request = self.diff_request + 1
  local request = self.diff_request
  local entry = self.entries[self.selected]
  self.current_diff = nil

  if self.diff_job then
    pcall(self.diff_job.kill, self.diff_job, 15)
    self.diff_job = nil
  end
  if not entry then
    set_lines(self.preview_buf, { "", "  Working tree clean." })
    vim.wo[self.preview_win].winbar = "%#NgitMuted# No changes "
    return
  end

  local key = self:cache_key(entry)
  local cached = self.cache:get(key)
  if cached then
    self:render_preview(entry, cached)
    return
  end

  set_lines(self.preview_buf, { "", ("  Loading %s…"):format(entry.file.path) })
  vim.wo[self.preview_win].winbar =
    ("%%#NgitMuted# %s · %s "):format(entry.section, statusline_escape(entry.file.path))

  vim.defer_fn(function()
    if self.closed or request ~= self.diff_request then
      return
    end
    self.diff_job = diff_backend.load(
      self.root,
      entry.section,
      entry.file.path,
      self.config.context,
      self.config.max_diff_bytes,
      function(diff, err)
        self.diff_job = nil
        if self.closed or request ~= self.diff_request then
          return
        end
        if not diff then
          set_lines(self.preview_buf, { "", "  " .. (err or "Unable to load diff") })
          return
        end
        self.cache:set(key, diff)
        self:render_preview(entry, diff)
      end
    )
  end, self.config.debounce_ms)
end

function Session:render_preview(entry, diff)
  self.current_diff = diff
  set_lines(self.preview_buf, #diff.lines > 0 and diff.lines or { "", "  No textual diff." })
  vim.wo[self.preview_win].winbar =
    ("%%#NgitMuted# %s · %s%s "):format(
      entry.section,
      statusline_escape(entry.file.path),
      diff.truncated and " · truncated" or ""
    )
  if valid_window(self.preview_win) then
    pcall(vim.api.nvim_win_set_cursor, self.preview_win, { 1, 0 })
  end
end

function Session:jump_hunk(direction)
  if not self.current_diff or #self.current_diff.hunks == 0 or not valid_window(self.preview_win) then
    return
  end
  vim.api.nvim_set_current_win(self.preview_win)
  local current = vim.api.nvim_win_get_cursor(self.preview_win)[1]
  local target
  if direction > 0 then
    for _, line in ipairs(self.current_diff.hunks) do
      if line > current then
        target = line
        break
      end
    end
    target = target or self.current_diff.hunks[1]
  else
    for index = #self.current_diff.hunks, 1, -1 do
      if self.current_diff.hunks[index] < current then
        target = self.current_diff.hunks[index]
        break
      end
    end
    target = target or self.current_diff.hunks[#self.current_diff.hunks]
  end
  vim.api.nvim_win_set_cursor(self.preview_win, { target, 0 })
end

function Session:mutation_patch()
  if vim.api.nvim_get_current_win() ~= self.preview_win or not self.current_diff then
    return nil
  end
  if self.current_diff.truncated then
    notify("Hunk actions are disabled for truncated previews", vim.log.levels.WARN)
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(self.preview_win)[1]
  return diff_backend.patch_at_hunk(self.current_diff.lines, line)
end

function Session:after_mutation(ok, err)
  if not ok then
    notify(err or "Git operation failed", vim.log.levels.ERROR)
    return
  end
  self:refresh()
end

function Session:stage()
  local entry = self.entries[self.selected]
  if not entry or entry.section == "staged" then
    return
  end
  local patch = entry.section == "unstaged" and self:mutation_patch() or nil
  if patch then
    mutate.apply_cached(self.root, patch, false, function(ok, err)
      self:after_mutation(ok, err)
    end)
  else
    mutate.stage_file(self.root, entry.file.path, function(ok, err)
      self:after_mutation(ok, err)
    end)
  end
end

function Session:unstage()
  local entry = self.entries[self.selected]
  if not entry or entry.section ~= "staged" then
    return
  end
  local patch = self:mutation_patch()
  local function apply(full_patch)
    mutate.apply_cached(self.root, full_patch, true, function(ok, err)
      self:after_mutation(ok, err)
    end)
  end
  if patch then
    apply(patch)
    return
  end
  diff_backend.load(
    self.root,
    "staged",
    entry.file.path,
    self.config.context,
    math.huge,
    function(diff, err)
      if not diff then
        notify(err or "Unable to construct unstage patch", vim.log.levels.ERROR)
        return
      end
      apply(diff.text)
    end
  )
end

function Session:discard()
  local entry = self.entries[self.selected]
  if not entry or entry.section ~= "unstaged" then
    return
  end
  if entry.file.kind == "untracked" then
    notify("ngit does not delete untracked files", vim.log.levels.WARN)
    return
  end

  local absolute_path = vim.fs.joinpath(self.root, entry.file.path)
  local buffer = vim.fn.bufnr(absolute_path)
  if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
    notify("Save or discard the modified Neovim buffer before restoring this file", vim.log.levels.WARN)
    return
  end

  local function perform()
    mutate.discard_file(self.root, entry.file.path, function(ok, err)
      self:after_mutation(ok, err)
    end)
  end
  if not self.config.confirm_discard then
    perform()
    return
  end
  vim.ui.select({ "Cancel", "Discard" }, {
    prompt = ("Discard worktree changes in %s?"):format(entry.file.path),
  }, function(choice)
    if choice == "Discard" then
      perform()
    end
  end)
end

function Session:open_file()
  local entry = self.entries[self.selected]
  if not entry then
    return
  end
  local path = vim.fs.joinpath(self.root, entry.file.path)
  if not vim.uv.fs_stat(path) then
    notify("The selected file does not exist in the worktree", vim.log.levels.WARN)
    return
  end
  self:close()
  vim.cmd.edit(vim.fn.fnameescape(path))
end

function Session:prompt_filter()
  vim.ui.input({
    prompt = "Filter changed files: ",
    default = self.filter or "",
  }, function(value)
    if value == nil or self.closed then
      return
    end
    self.filter = value ~= "" and value or nil
    self:render_files()
    self:load_preview()
  end)
end

function Session:show_help()
  notify(table.concat({
    "ngit mappings",
    "",
    "j/k                 next/previous file (file panel)",
    "<CR>                focus selected diff",
    "<Tab>/<S-Tab>      next/previous changed file",
    "[c/]c               previous/next hunk",
    "s                   stage file, or hunk from preview",
    "u                   unstage file, or hunk from preview",
    "X                   discard tracked worktree changes",
    "o                   open selected file",
    "/                   filter changed files",
    "r                   refresh",
    "<leader>e/d        focus files/diff",
    "q                   close",
  }, "\n"))
end

return Session
