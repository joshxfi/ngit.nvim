local config_module = require("ngit.config")
local actions = require("ngit.ui.actions")
local branch_backend = require("ngit.git.branch")
local conflict_backend = require("ngit.git.conflict")
local diff_backend = require("ngit.git.diff")
local log_backend = require("ngit.git.log")
local mutate = require("ngit.git.mutate")
local remote_backend = require("ngit.git.remote")
local sequencer_backend = require("ngit.git.sequencer")
local stash_backend = require("ngit.git.stash")
local status_backend = require("ngit.git.status")
local Dashboard = require("ngit.ui.dashboard")
local DiffView = require("ngit.ui.diff_view")
local Help = require("ngit.ui.help")
local Render = require("ngit.ui.render")
local Lru = require("ngit.util.lru")

local Session = {}
Session.__index = Session

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

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function valid_tab(tab)
  return tab and vim.api.nvim_tabpage_is_valid(tab)
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
  if not entry then
    return nil
  elseif entry.kind == "commit" then
    return "commit\0" .. entry.commit.oid
  elseif entry.kind == "branch" then
    return "branch\0" .. entry.branch.refname
  elseif entry.kind == "stash" then
    return "stash\0" .. entry.stash.oid
  end
  return entry.section .. "\0" .. entry.file.path
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

local function short_oid(oid)
  return oid and oid:sub(1, 8) or "????????"
end

local function calendar_date(timestamp)
  if not timestamp or timestamp == 0 then
    return "unknown"
  end
  return os.date("%Y-%m-%d", timestamp)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit" })
end

---@param root string
function Session.new(root)
  next_id = next_id + 1
  local panels = {}
  for _, id in ipairs(Dashboard.panel_order) do
    panels[id] = {
      id = id,
      data = nil,
      entries = {},
      row_entries = {},
      selected = 1,
      filter = nil,
      has_more = false,
      loading = true,
      error = nil,
      request = 0,
      job = nil,
    }
  end
  local self = setmetatable({
    id = next_id,
    root = root,
    config = config_module.get(),
    current_view = "status",
    active_panel = "status",
    panels = panels,
    status = nil,
    collection = nil,
    has_more = false,
    entries = {},
    row_entries = {},
    selected = 1,
    filter = nil,
    generation = 0,
    status_request = 0,
    operation_request = 0,
    diff_request = 0,
    diff_job = nil,
    status_job = nil,
    operation_job = nil,
    operation = nil,
    current_diff = nil,
    closed = false,
    cache = nil,
    refresh_generation = 0,
    last_result = "",
    last_result_ok = nil,
  }, Session)
  self.cache = Lru.new(self.config.cache_entries)
  return self
end

function Session:active_state()
  return self.panels[self.active_panel]
end

function Session:sync_active_aliases()
  local panel = self:active_state()
  self.current_view = self.active_panel
  self.entries = panel.entries
  self.row_entries = panel.row_entries
  self.selected = panel.selected
  self.filter = panel.filter
  self.collection = panel.data
  self.has_more = panel.has_more
  local ui_panel = self.dashboard and self.dashboard.panels[self.active_panel]
  if ui_panel then
    self.files_win = ui_panel.window
    self.files_buf = ui_panel.buffer
  end
end

function Session:selected_entry()
  local panel = self:active_state()
  return panel.entries[panel.selected]
end

function Session:open()
  self.origin_tab = vim.api.nvim_get_current_tabpage()
  self.origin_win = vim.api.nvim_get_current_win()
  self:set_statusline_hidden(true)
  local ok, dashboard = pcall(Dashboard.open, self.id, self.config)
  if not ok then
    self:set_statusline_hidden(false)
    error(dashboard, 0)
  end
  self.dashboard = dashboard
  self.tab = self.dashboard.tab
  self:set_statusline_hidden(true)
  self.layout = "dashboard"
  self.preview_win = self.dashboard.preview.window
  self.preview_buf = self.dashboard.preview.buffer
  self.files_win = self.dashboard.panels.status.window
  self.files_buf = self.dashboard.panels.status.buffer
  self:sync_active_aliases()

  self:install_mappings()
  self:install_autocommands()
  self.dashboard:focus_panel("status")
  self:refresh()
end

function Session:set_statusline_hidden(hidden)
  if not self.config.hide_statusline then
    return
  end
  if hidden then
    if self.tab and not valid_tab(self.tab) then
      return
    end
    if not self.statusline_hidden then
      self.statusline_restore = vim.o.laststatus
      self.statusline_hidden = true
    end
    local lualine = package.loaded.lualine
    if
      not self.lualine_hidden
      and type(lualine) == "table"
      and type(lualine.hide) == "function"
    then
      local ok = pcall(lualine.hide, { place = { "statusline" } })
      self.lualine_hidden = ok
    end
    -- Native split windows always reserve status rows between horizontal
    -- splits, even with laststatus=0. Global status mode removes those
    -- per-window rows and leaves one blank row below the dashboard instead.
    if vim.o.laststatus ~= 3 then
      vim.o.laststatus = 3
      if self.dashboard then
        self.dashboard:resize()
      end
    end
  elseif self.statusline_hidden then
    local restore = self.statusline_restore or 2
    local lualine = package.loaded.lualine
    if self.lualine_hidden and type(lualine) == "table" and type(lualine.hide) == "function" then
      pcall(lualine.hide, { place = { "statusline" }, unhide = true })
    end
    self.lualine_hidden = false
    vim.o.laststatus = restore
    self.statusline_restore = nil
    self.statusline_hidden = false
    if self.dashboard and valid_tab(self.tab) then
      self.dashboard:resize()
    end
  end
end

function Session:install_mappings()
  local mappings = self.config.mappings
  local panel_buffers = {}
  local all_buffers = self.dashboard:all_buffers()
  for _, id in ipairs(Dashboard.panel_order) do
    panel_buffers[id] = self.dashboard.panels[id].buffer
    all_buffers[#all_buffers + 1] = panel_buffers[id]
  end

  local function map(key, callback, description, buffers)
    if not key or key == false or key == "" then
      return
    end
    for _, buffer in ipairs(buffers or all_buffers) do
      vim.keymap.set("n", key, callback, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "ngit: " .. description,
      })
    end
  end

  for _, id in ipairs(Dashboard.panel_order) do
    local selected_id = id
    map(mappings.next_item, function()
      self:focus_panel(selected_id)
      self:select_relative(1)
    end, "next item", { panel_buffers[id] })
    map(mappings.prev_item, function()
      self:focus_panel(selected_id)
      self:select_relative(-1)
    end, "previous item", { panel_buffers[id] })
    map(mappings.select, function()
      self:focus_panel(selected_id)
      self.dashboard:focus_preview()
    end, "focus selected preview", { panel_buffers[id] })
  end

  map(mappings.next_panel, function()
    self:focus_relative_panel(1)
  end, "next panel")
  map(mappings.prev_panel, function()
    self:focus_relative_panel(-1)
  end, "previous panel")
  map(mappings.status_view, function()
    self:focus_panel("status")
  end, "status panel")
  map(mappings.commit_view, function()
    self:focus_panel("commits")
  end, "commits panel")
  map(mappings.branch_view, function()
    self:focus_panel("branches")
  end, "branches panel")
  map(mappings.stash_view, function()
    self:focus_panel("stashes")
  end, "stashes panel")
  map(mappings.focus_status, function()
    self:focus_panel("status")
  end, "status panel")
  map(mappings.focus_branches, function()
    self:focus_panel("branches")
  end, "branches panel")
  map(mappings.focus_commits, function()
    self:focus_panel("commits")
  end, "commits panel")
  map(mappings.focus_stashes, function()
    self:focus_panel("stashes")
  end, "stashes panel")
  map(mappings.next_file, function()
    self:select_relative(1)
  end, "next item")
  map(mappings.prev_file, function()
    self:select_relative(-1)
  end, "previous item")
  local preview_buffers = {
    self.dashboard.preview.left.buffer,
    self.dashboard.preview.right.buffer,
    self.dashboard.preview.unified.buffer,
  }
  map(mappings.next_hunk, function()
    self:jump_hunk(1)
  end, "next hunk", preview_buffers)
  map(mappings.prev_hunk, function()
    self:jump_hunk(-1)
  end, "previous hunk", preview_buffers)
  map(mappings.next_diff_file, function()
    self:jump_diff_file(1)
  end, "next diff file", preview_buffers)
  map(mappings.prev_diff_file, function()
    self:jump_diff_file(-1)
  end, "previous diff file", preview_buffers)
  map(mappings.toggle_diff, function()
    self:toggle_diff_layout()
  end, "toggle diff layout", preview_buffers)
  map(mappings.stage, function()
    self:stage()
  end, "stage hunk", preview_buffers)
  map(mappings.unstage, function()
    self:unstage()
  end, "unstage hunk", preview_buffers)
  map(mappings.focus_files, function()
    self:focus_panel(self.active_panel)
  end, "focus active panel")
  map(mappings.focus_preview, function()
    self.dashboard:focus_preview()
  end, "focus preview")
  map("<Esc>", function()
    self:focus_panel(self.active_panel)
  end, "return to active panel", preview_buffers)

  for _, action in ipairs(actions.definitions()) do
    local key = mappings[action.mapping]
    local buffers = {}
    if action.global then
      buffers = all_buffers
    elseif action.panels then
      for _, id in ipairs(Dashboard.panel_order) do
        if action.panels[id] then
          buffers[#buffers + 1] = panel_buffers[id]
        end
      end
    elseif action.panel_only then
      for _, id in ipairs(Dashboard.panel_order) do
        buffers[#buffers + 1] = panel_buffers[id]
      end
    end
    if #buffers > 0 then
      local selected_action = action
      map(key, function()
        local method = self[selected_action.method]
        if method then
          method(self, unpack(selected_action.args or {}))
        end
      end, action.label:lower(), buffers)
    end
  end
end

function Session:install_autocommands()
  self.augroup = vim.api.nvim_create_augroup(("ngit_session_%d"):format(self.id), { clear = true })
  vim.api.nvim_create_autocmd("TabEnter", {
    group = self.augroup,
    callback = function()
      if not self.closed and vim.api.nvim_get_current_tabpage() == self.tab then
        self:set_statusline_hidden(true)
      end
    end,
  })
  vim.api.nvim_create_autocmd("TabLeave", {
    group = self.augroup,
    callback = function()
      if not self.closed and vim.api.nvim_get_current_tabpage() == self.tab then
        self:set_statusline_hidden(false)
      end
    end,
  })
  for _, id in ipairs(Dashboard.panel_order) do
    local panel_id = id
    local ui_panel = self.dashboard.panels[id]
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = ui_panel.buffer,
      callback = function()
        if self.closed or not valid_window(ui_panel.window) then
          return
        end
        if self.active_panel ~= panel_id then
          self:focus_panel(panel_id, false)
        end
        local row = vim.api.nvim_win_get_cursor(ui_panel.window)[1]
        local entry = self.panels[panel_id].row_entries[row]
        if entry then
          self:select_entry(entry)
        end
      end,
    })
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self.augroup,
      buffer = ui_panel.buffer,
      callback = function()
        if not self.closed and self.active_panel ~= panel_id then
          self:focus_panel(panel_id, false)
        end
      end,
    })
  end
  for _, buffer in ipairs(self.dashboard:all_buffers()) do
    vim.api.nvim_create_autocmd("WinEnter", {
      group = self.augroup,
      buffer = buffer,
      callback = function()
        if not self.closed then
          self:set_statusline_hidden(true)
          self.dashboard:reassert_statusline(vim.api.nvim_get_current_win())
        end
      end,
    })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.dashboard.panels.status.buffer,
    once = true,
    callback = function()
      self:dispose()
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = self.augroup,
    callback = function()
      if not self.closed then
        self.dashboard:resize()
        if self.current_diff_models and not self.diff_layout_override then
          self:render_diff_layout(self.dashboard:desired_preview_layout())
        end
        self:update_actions()
      end
    end,
  })

  if self.config.auto_refresh then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = self.augroup,
      callback = function()
        self:schedule_refresh("status")
      end,
    })
    vim.api.nvim_create_autocmd({ "FocusGained", "ShellCmdPost" }, {
      group = self.augroup,
      callback = function()
        self:schedule_refresh("full")
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
  self.operation_request = self.operation_request + 1
  self.refresh_generation = self.refresh_generation + 1
  self.diff_request = self.diff_request + 1
  if self.diff_job then
    pcall(self.diff_job.kill, self.diff_job, 15)
    self.diff_job = nil
  end
  if self.status_job then
    pcall(self.status_job.kill, self.status_job, 15)
    self.status_job = nil
  end
  for _, panel in pairs(self.panels) do
    panel.request = panel.request + 1
    if panel.job then
      pcall(panel.job.kill, panel.job, 15)
      panel.job = nil
    end
  end
  if self.operation_job then
    pcall(self.operation_job.kill, self.operation_job, 15)
    self.operation_job = nil
  end
  if self.remote_console then
    self.remote_console:close()
    self.remote_console = nil
  end
  if self.commit_editor then
    self.commit_editor:close()
    self.commit_editor = nil
  end
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  self:set_statusline_hidden(false)
  if self.dashboard then
    self.dashboard:dispose()
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

function Session:schedule_refresh(scope)
  scope = scope or "full"
  if scope == "full" or not self.pending_refresh_scope then
    self.pending_refresh_scope = scope
  end
  self.refresh_timer = (self.refresh_timer or 0) + 1
  local token = self.refresh_timer
  vim.defer_fn(function()
    if not self.closed and token == self.refresh_timer then
      local pending = self.pending_refresh_scope or "full"
      self.pending_refresh_scope = nil
      if pending == "status" then
        self:refresh_status()
      else
        self:refresh()
      end
    end
  end, self.config.refresh_debounce_ms)
end

function Session:switch_view(view)
  self:focus_panel(view)
end

function Session:focus_panel(id, set_window)
  if self.closed or not self.panels[id] then
    return
  end
  self.active_panel = id
  self:sync_active_aliases()
  self.dashboard.active_panel = id
  self.dashboard:refresh_winbars()
  self.dashboard:reflow()
  if set_window ~= false then
    self.dashboard:focus_panel(id)
  end
  self:update_file_cursor()
  self:load_preview()
  self:update_actions()
end

function Session:focus_relative_panel(delta)
  local current = 1
  for index, id in ipairs(Dashboard.panel_order) do
    if id == self.active_panel then
      current = index
      break
    end
  end
  local target = ((current - 1 + delta) % #Dashboard.panel_order) + 1
  self:focus_panel(Dashboard.panel_order[target])
end

function Session:set_result(message, ok)
  self.last_result = (message or ""):gsub("[\r\n]+", " "):sub(1, 160)
  self.last_result_ok = ok
  self:update_actions()
end

function Session:update_actions()
  if self.closed or not self.dashboard then
    return
  end
  local panel = self:active_state()
  local context = {
    panel = self.active_panel,
    entry = panel.entries[panel.selected],
    operation = self.operation,
    has_more = panel.has_more,
  }
  local items = actions.for_context(context, self.config.mappings)
  local group
  if self.last_result_ok == true then
    group = "NgitSuccess"
  elseif self.last_result_ok == false then
    group = "NgitFailure"
  end
  self.dashboard:render_actions(items, self.last_result, group)
end

function Session:refresh()
  if self.closed then
    return
  end
  self.refresh_generation = self.refresh_generation + 1
  self.generation = self.refresh_generation
  local generation = self.refresh_generation
  self.cache:clear()
  self.diff_request = self.diff_request + 1
  if self.diff_job then
    pcall(self.diff_job.kill, self.diff_job, 15)
    self.diff_job = nil
  end

  local preferred = {}
  for id, panel in pairs(self.panels) do
    preferred[id] = entry_key(panel.entries[panel.selected])
    panel.request = panel.request + 1
    panel.loading = true
    panel.error = nil
    if panel.job then
      pcall(panel.job.kill, panel.job, 15)
      panel.job = nil
    end
    panel.entries = {}
    panel.row_entries = {}
    self.dashboard:render_panel(id, {
      lines = { "", ("  Loading %s…"):format(id) },
      count = 0,
      selected = 0,
      empty = true,
      detail = "refreshing",
    })
  end
  self:sync_active_aliases()

  self.operation = nil
  self.operation_request = self.operation_request + 1
  local operation_request = self.operation_request
  if self.operation_job then
    pcall(self.operation_job.kill, self.operation_job, 15)
    self.operation_job = nil
  end

  local status_panel = self.panels.status
  local status_request = status_panel.request
  local status_job
  status_job = status_backend.load(self.root, function(status, err)
    if status_panel.job == status_job then
      status_panel.job = nil
    end
    if self.status_job == status_job then
      self.status_job = nil
    end
    if
      self.closed
      or generation ~= self.refresh_generation
      or status_request ~= status_panel.request
    then
      return
    end
    if not status then
      self:render_panel_error("status", err or "Unable to load Git status")
      return
    end

    self.status = status
    status_panel.data = status
    status_panel.loading = false
    self:render_files(preferred.status)
    if self.active_panel == "status" then
      self:load_preview()
    end
  end)
  status_panel.job = status_job
  self.status_job = status_job

  local operation_job
  operation_job = sequencer_backend.detect(self.root, function(operation)
    if self.operation_job == operation_job then
      self.operation_job = nil
    end
    if
      self.closed
      or generation ~= self.refresh_generation
      or operation_request ~= self.operation_request
    then
      return
    end
    self.operation = operation
    if self.status then
      self:render_files(preferred.status)
    end
    self:update_actions()
  end)
  self.operation_job = operation_job

  local function load_collection(id, start)
    local panel = self.panels[id]
    local request = panel.request
    local collection_job
    collection_job = start(function(items, has_more, err)
      if panel.job == collection_job then
        panel.job = nil
      end
      if self.closed or generation ~= self.refresh_generation or request ~= panel.request then
        return
      end
      if not items then
        self:render_panel_error(id, err or ("Unable to load " .. id))
        return
      end
      panel.data = items
      panel.has_more = has_more == true
      panel.loading = false
      self:render_collection(id, preferred[id])
      if self.active_panel == id then
        self:load_preview()
      end
    end)
    panel.job = collection_job
  end

  load_collection("commits", function(done)
    return log_backend.list(
      self.root,
      { limit = self.config.commit_limit },
      function(items, has_more, err)
        done(items, has_more, err)
      end
    )
  end)
  load_collection("branches", function(done)
    return branch_backend.list(self.root, function(items, err)
      done(items, false, err)
    end)
  end)
  load_collection("stashes", function(done)
    return stash_backend.list(self.root, function(items, err)
      done(items, false, err)
    end)
  end)
  self:update_actions()
end

function Session:refresh_status()
  if self.closed then
    return
  end
  local panel = self.panels.status
  local preferred = entry_key(panel.entries[panel.selected])
  self.generation = self.generation + 1
  panel.request = panel.request + 1
  panel.loading = true
  panel.error = nil
  local request = panel.request

  if panel.job then
    pcall(panel.job.kill, panel.job, 15)
    panel.job = nil
  end
  if self.status_job then
    pcall(self.status_job.kill, self.status_job, 15)
    self.status_job = nil
  end
  if self.active_panel == "status" then
    self.diff_request = self.diff_request + 1
    self.current_diff = nil
    self.current_diff_models = nil
    self.current_diff_opts = nil
    if self.diff_job then
      pcall(self.diff_job.kill, self.diff_job, 15)
      self.diff_job = nil
    end
    self.dashboard:render_preview({ "", "  Refreshing working tree…" }, "Changes")
  end

  local status_job
  status_job = status_backend.load(self.root, function(status, err)
    if panel.job == status_job then
      panel.job = nil
    end
    if self.status_job == status_job then
      self.status_job = nil
    end
    if self.closed or request ~= panel.request then
      return
    end
    if not status then
      self:render_panel_error("status", err or "Unable to load Git status")
      return
    end
    self.status = status
    panel.data = status
    panel.loading = false
    self:render_files(preferred)
    if self.active_panel == "status" then
      self:load_preview()
    end
  end)
  panel.job = status_job
  self.status_job = status_job

  self.operation_request = self.operation_request + 1
  local operation_request = self.operation_request
  if self.operation_job then
    pcall(self.operation_job.kill, self.operation_job, 15)
    self.operation_job = nil
  end
  local operation_job
  operation_job = sequencer_backend.detect(self.root, function(operation)
    if self.operation_job == operation_job then
      self.operation_job = nil
    end
    if self.closed or operation_request ~= self.operation_request then
      return
    end
    self.operation = operation
    if self.status then
      self:render_files(preferred)
    end
    self:update_actions()
  end)
  self.operation_job = operation_job
  self:update_actions()
end

function Session:render_panel_error(id, message)
  local panel = self.panels[id]
  panel.loading = false
  panel.error = message
  panel.entries = {}
  panel.row_entries = {}
  panel.selected = 1
  self.dashboard:render_panel(id, {
    lines = { "", "  " .. message },
    count = 0,
    selected = 0,
    empty = true,
    detail = "error",
  })
  if id == self.active_panel then
    self:sync_active_aliases()
    self.dashboard:render_preview({ "", "  " .. message }, "Unable to load")
  end
  notify(message, vim.log.levels.ERROR)
end

function Session:render_files(preferred_key)
  local panel = self.panels.status
  if not self.status or not self.dashboard then
    return
  end
  local groups = display_entries(self.status, panel.filter)
  local lines = {}
  local row_entries = {}
  local entries = {}
  local section_rows = {}
  local row_highlights = {}

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
        local rendered = Render.status(
          sign_for(self.config, entry),
          display_path(entry),
          section_highlights[entry.section]
        )
        lines[#lines + 1] = rendered.text
        for _, span in ipairs(rendered.spans) do
          span.row = #lines - 1
          row_highlights[#row_highlights + 1] = span
        end
        row_entries[#lines] = entry
        entry.row = #lines
        entry.index = #entries
      end
    end
  end

  if #entries == 0 then
    lines = {
      "",
      panel.filter and "  No changes match the current filter." or "  Working tree clean.",
    }
  end

  panel.entries = entries
  panel.row_entries = row_entries
  panel.selected = math.min(panel.selected, math.max(1, #entries))
  if preferred_key then
    for index, entry in ipairs(entries) do
      if entry_key(entry) == preferred_key then
        panel.selected = index
        break
      end
    end
  end

  local suffix = ""
  if self.status.ahead > 0 or self.status.behind > 0 then
    suffix = (" ↑%d ↓%d"):format(self.status.ahead, self.status.behind)
  end
  if self.operation then
    suffix = suffix .. (" · %s in progress"):format(self.operation)
  end
  if panel.filter and panel.filter ~= "" then
    suffix = suffix .. (" · /%s"):format(panel.filter)
  end
  self.dashboard:render_panel("status", {
    lines = lines,
    count = #entries,
    selected = #entries > 0 and panel.selected or 0,
    selected_row = entries[panel.selected] and entries[panel.selected].row or nil,
    empty = #entries == 0,
    detail = self.status.branch .. suffix,
    highlights = vim.list_extend(
      row_highlights,
      vim.tbl_map(function(item)
        return { row = item.row, group = section_highlights[item.section], line = true }
      end, section_rows)
    ),
  })
  if self.active_panel == "status" then
    self:sync_active_aliases()
    self:update_actions()
  end
end

function Session:refresh_collection()
  self:refresh()
end

function Session:render_collection(view, preferred_key)
  local panel = self.panels[view]
  local lines = {}
  local entries = {}
  local row_entries = {}
  local row_highlights = {}
  local needle = panel.filter and panel.filter:lower() or nil

  for _, item in ipairs(panel.data or {}) do
    local entry
    local line
    local searchable
    if view == "commits" then
      entry = { kind = "commit", commit = item }
      local decoration = item.decorations ~= "" and ("  " .. item.decorations) or ""
      local rendered = Render.commit(
        short_oid(item.oid),
        calendar_date(item.timestamp),
        item.subject,
        item.decorations
      )
      line = rendered.text
      entry.highlights = rendered.spans
      searchable =
        table.concat({ item.oid, item.author, item.email, item.subject, item.decorations }, " ")
    elseif view == "branches" then
      entry = { kind = "branch", branch = item }
      local marker = item.current and "*" or (item.remote and "r" or " ")
      local upstream = item.upstream ~= "" and (" → " .. item.upstream .. " " .. item.track) or ""
      local rendered = Render.branch(marker, item.name, item.subject, upstream, item.remote)
      line = rendered.text
      entry.highlights = rendered.spans
      searchable = table.concat({ item.name, item.upstream, item.subject }, " ")
    else
      entry = { kind = "stash", stash = item }
      local rendered = Render.stash(item.ref, calendar_date(item.timestamp), item.subject)
      line = rendered.text
      entry.highlights = rendered.spans
      searchable = item.ref .. " " .. item.subject
    end

    if not needle or needle == "" or searchable:lower():find(needle, 1, true) then
      entries[#entries + 1] = entry
      lines[#lines + 1] = line
      entry.row = #lines
      entry.index = #entries
      row_entries[#lines] = entry
      for _, span in ipairs(entry.highlights or {}) do
        span.row = #lines - 1
        row_highlights[#row_highlights + 1] = span
      end
    end
  end

  if #entries == 0 then
    lines = { "", panel.filter and "  No entries match the filter." or "  No entries." }
  elseif view == "commits" and panel.has_more then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  Press L to load more commits."
  end

  panel.entries = entries
  panel.row_entries = row_entries
  panel.selected = math.min(panel.selected, math.max(1, #entries))
  if preferred_key then
    for index, entry in ipairs(entries) do
      if entry_key(entry) == preferred_key then
        panel.selected = index
        break
      end
    end
  end
  self.dashboard:render_panel(view, {
    lines = lines,
    count = #entries,
    selected = #entries > 0 and panel.selected or 0,
    selected_row = entries[panel.selected] and entries[panel.selected].row or nil,
    empty = #entries == 0,
    detail = panel.filter and ("/" .. panel.filter) or "",
    highlights = row_highlights,
  })
  if self.active_panel == view then
    self:sync_active_aliases()
    self:update_actions()
  end
end

function Session:update_file_cursor()
  local panel = self:active_state()
  local entry = panel.entries[panel.selected]
  local window = self.dashboard.panels[self.active_panel].window
  if entry and valid_window(window) then
    pcall(vim.api.nvim_win_set_cursor, window, { entry.row, 0 })
  end
end

function Session:select_entry(target)
  local panel = self:active_state()
  for index, entry in ipairs(panel.entries) do
    if entry == target then
      if panel.selected ~= index then
        panel.selected = index
        self:sync_active_aliases()
        self.dashboard:refresh_winbars()
        self:load_preview()
        self:update_actions()
      end
      return
    end
  end
end

function Session:select_relative(delta)
  local panel = self:active_state()
  if #panel.entries == 0 then
    return
  end
  panel.selected = ((panel.selected - 1 + delta) % #panel.entries) + 1
  self:sync_active_aliases()
  self.dashboard:refresh_winbars()
  self:update_file_cursor()
  self:load_preview()
  self:update_actions()
end

function Session:cache_key(entry)
  if entry.kind == "commit" then
    return table.concat({ "commit", entry.commit.oid }, "\0")
  elseif entry.kind == "branch" then
    return table.concat({ "branch", entry.branch.oid }, "\0")
  elseif entry.kind == "stash" then
    return table.concat({ "stash", entry.stash.oid }, "\0")
  end
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
  local panel_id = self.active_panel
  local panel = self:active_state()
  local entry = panel.entries[panel.selected]
  self.current_diff = nil
  self.current_diff_models = nil
  self.current_diff_opts = nil

  if self.diff_job then
    pcall(self.diff_job.kill, self.diff_job, 15)
    self.diff_job = nil
  end
  if not entry then
    local message = panel_id == "status" and "Working tree clean." or "No entries."
    self.dashboard:render_preview({ "", "  " .. message }, "No changes")
    return
  end

  local key = self:cache_key(entry)
  local cached = self.cache:get(key)
  if cached then
    self:render_preview(entry, cached)
    return
  end

  local title = self:preview_title(entry)
  self.dashboard:render_preview({ "", ("  Loading %s…"):format(title) }, title)

  vim.defer_fn(function()
    if self.closed or request ~= self.diff_request or panel_id ~= self.active_panel then
      return
    end
    local preview_job
    local function complete(diff, err)
      if self.diff_job == preview_job then
        self.diff_job = nil
      end
      if self.closed or request ~= self.diff_request or panel_id ~= self.active_panel then
        return
      end
      if not diff then
        self.dashboard:render_preview(
          { "", "  " .. (err or "Unable to load diff") },
          "Unable to load preview"
        )
        return
      end
      self.cache:set(key, diff)
      self:render_preview(entry, diff)
    end
    if entry.kind == "commit" then
      preview_job =
        log_backend.show(self.root, entry.commit.oid, self.config.max_diff_bytes, complete)
    elseif entry.kind == "branch" then
      preview_job =
        branch_backend.preview(self.root, entry.branch, self.config.max_diff_bytes, complete)
    elseif entry.kind == "stash" then
      preview_job = stash_backend.show(self.root, entry.stash, self.config.max_diff_bytes, complete)
    else
      preview_job = diff_backend.load(
        self.root,
        entry.section,
        entry.file.path,
        self.config.context,
        self.config.max_diff_bytes,
        complete
      )
    end
    self.diff_job = preview_job
  end, self.config.debounce_ms)
end

function Session:preview_title(entry)
  if entry.kind == "commit" then
    return ("%s · %s"):format(short_oid(entry.commit.oid), entry.commit.subject)
  elseif entry.kind == "branch" then
    return ("branch · %s"):format(entry.branch.name)
  elseif entry.kind == "stash" then
    return ("stash · %s"):format(entry.stash.ref)
  end
  return ("%s · %s"):format(entry.section, entry.file.path)
end

function Session:render_preview(entry, diff)
  self.current_diff = diff
  local opts = { title = self:preview_title(entry), entry = entry }
  local split = DiffView.split(diff, opts)
  local models = {
    split = split,
    unified = nil,
  }
  self.current_diff_models = models
  self.current_diff_opts = opts
  local layout = self.diff_layout_override or self.dashboard:desired_preview_layout()
  self:render_diff_layout(layout)
  self.preview_win = self.dashboard.preview.window
  self.preview_buf = self.dashboard.preview.buffer
end

function Session:render_diff_layout(layout)
  if not self.current_diff or not self.current_diff_models then
    return
  end
  if layout == "unified" and not self.current_diff_models.unified then
    self.current_diff_models.unified =
      DiffView.unified(self.current_diff, self.current_diff_opts, self.current_diff_models.split)
  end
  self.dashboard:render_diff(self.current_diff_models, layout, DiffView.filetype(self.current_diff))
  self.preview_win = self.dashboard.preview.window
  self.preview_buf = self.dashboard.preview.buffer
end

function Session:preview_pane()
  if not self.current_diff_models then
    return nil
  end
  local current = vim.api.nvim_get_current_win()
  if self.dashboard.preview.layout == "unified" then
    if current ~= self.dashboard.preview.unified.window then
      return nil
    end
    return self.current_diff_models.unified.unified, self.dashboard.preview.unified.window
  elseif current == self.dashboard.preview.left.window then
    return self.current_diff_models.split.left, self.dashboard.preview.left.window
  elseif current == self.dashboard.preview.right.window then
    return self.current_diff_models.split.right, self.dashboard.preview.right.window
  end
  return nil
end

function Session:jump_hunk(direction)
  local pane, window = self:preview_pane()
  local hunks = self.dashboard.preview.layout == "unified"
      and self.current_diff_models.unified.hunks
    or self.current_diff_models.split.hunks
  if not pane or #hunks == 0 or not valid_window(window) then
    return
  end
  vim.api.nvim_set_current_win(window)
  local current = vim.api.nvim_win_get_cursor(window)[1]
  local target
  if direction > 0 then
    for _, line in ipairs(hunks) do
      if line > current then
        target = line
        break
      end
    end
    target = target or hunks[1]
  else
    for index = #hunks, 1, -1 do
      if hunks[index] < current then
        target = hunks[index]
        break
      end
    end
    target = target or hunks[#hunks]
  end
  if self.dashboard.preview.layout == "side_by_side" then
    pcall(vim.api.nvim_win_set_cursor, self.dashboard.preview.left.window, { target, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.dashboard.preview.right.window, { target, 0 })
  else
    vim.api.nvim_win_set_cursor(window, { target, 0 })
  end
end

function Session:mutation_patch()
  local pane = self:preview_pane()
  if not pane or not self.current_diff then
    return nil
  end
  if self.current_diff.truncated then
    notify("Hunk actions are disabled for truncated previews", vim.log.levels.WARN)
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(vim.api.nvim_get_current_win())[1]
  local unified_start = pane.row_hunks[line]
  if not unified_start then
    return nil
  end
  return diff_backend.patch_at_hunk(self.current_diff.lines, unified_start)
end

function Session:jump_diff_file(direction)
  local pane, window = self:preview_pane()
  if not pane or not valid_window(window) or #pane.file_rows == 0 then
    return
  end
  local current = vim.api.nvim_win_get_cursor(window)[1]
  local target
  if direction > 0 then
    for _, row in ipairs(pane.file_rows) do
      if row > current then
        target = row
        break
      end
    end
    target = target or pane.file_rows[1]
  else
    for index = #pane.file_rows, 1, -1 do
      if pane.file_rows[index] < current then
        target = pane.file_rows[index]
        break
      end
    end
    target = target or pane.file_rows[#pane.file_rows]
  end
  vim.api.nvim_win_set_cursor(window, { target, 0 })
end

function Session:toggle_diff_layout()
  if not self.current_diff_models or not self.current_diff then
    return
  end
  self.diff_layout_override = self.dashboard.preview.layout == "side_by_side" and "unified"
    or "side_by_side"
  self:render_diff_layout(self.diff_layout_override)
end

function Session:after_mutation(ok, err)
  if not ok then
    self:set_result(err or "Git operation failed", false)
    notify(err or "Git operation failed", vim.log.levels.ERROR)
    return
  end
  self:set_result("Git operation completed", true)
  self:refresh()
end

function Session:stage()
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
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
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
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
  mutate.unstage_file(self.root, entry.file.path, function(ok, err)
    self:after_mutation(ok, err)
  end)
end

function Session:discard()
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
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
    notify(
      "Save or discard the modified Neovim buffer before restoring this file",
      vim.log.levels.WARN
    )
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
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
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
  local panel_id = self.active_panel
  local panel = self:active_state()
  vim.ui.input({
    prompt = ("Filter %s: "):format(panel_id),
    default = panel.filter or "",
  }, function(value)
    if value == nil or self.closed then
      return
    end
    panel.filter = value ~= "" and value or nil
    if panel_id == "status" then
      self:render_files()
    else
      self:render_collection(panel_id)
    end
    self:sync_active_aliases()
    self:load_preview()
  end)
end

function Session:primary_action()
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.kind == "branch" then
    if entry.branch.current then
      notify("Already on " .. entry.branch.name)
      return
    end
    branch_backend.switch(self.root, entry.branch, function(ok, err)
      self:after_mutation(ok, err)
    end)
  elseif entry.kind == "commit" then
    vim.fn.setreg("+", entry.commit.oid)
    notify("Copied " .. entry.commit.oid)
  elseif valid_window(self.preview_win) then
    vim.api.nvim_set_current_win(self.preview_win)
  end
end

function Session:new_item()
  if self.active_panel == "branches" then
    vim.ui.input({ prompt = "New branch: " }, function(name)
      if not name or name == "" or self.closed then
        return
      end
      branch_backend.create(self.root, name, function(ok, err)
        self:after_mutation(ok, err)
      end)
    end)
  elseif self.active_panel == "stashes" then
    vim.ui.input({ prompt = "Stash message (optional): " }, function(message)
      if message == nil or self.closed then
        return
      end
      stash_backend.push(self.root, message, function(ok, err)
        self:after_mutation(ok, err)
      end)
    end)
  end
end

function Session:delete_item()
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.kind == "branch" then
    if entry.branch.remote then
      notify("Deleting remote branches is not supported yet", vim.log.levels.WARN)
      return
    elseif entry.branch.current then
      notify("The current branch cannot be deleted", vim.log.levels.WARN)
      return
    end
    vim.ui.select({ "Cancel", "Delete" }, {
      prompt = ("Delete merged branch %s?"):format(entry.branch.name),
    }, function(choice)
      if choice == "Delete" then
        branch_backend.delete(self.root, entry.branch.name, false, function(ok, err)
          self:after_mutation(ok, err)
        end)
      end
    end)
  elseif entry.kind == "stash" then
    vim.ui.select({ "Cancel", "Drop" }, {
      prompt = ("Drop %s permanently?"):format(entry.stash.ref),
    }, function(choice)
      if choice == "Drop" then
        stash_backend.drop(self.root, entry.stash, function(ok, err)
          self:after_mutation(ok, err)
        end)
      end
    end)
  end
end

function Session:apply_item(pop)
  local entry = self:selected_entry()
  if not entry or entry.kind ~= "stash" then
    return
  end
  local action = pop and stash_backend.pop or stash_backend.apply
  action(self.root, entry.stash, function(ok, err)
    self:after_mutation(ok, err)
  end)
end

function Session:prompt_commit(amend)
  if self.active_panel ~= "status" then
    return
  end
  if self.commit_editor and not self.commit_editor.closed then
    if valid_window(self.commit_editor.window) then
      vim.api.nvim_set_current_win(self.commit_editor.window)
    end
    return
  end
  local function open_editor(message)
    if self.closed then
      return
    end
    local CommitEditor = require("ngit.ui.commit_editor")
    self.commit_editor = CommitEditor.new(self.root, {
      amend = amend,
      message = message,
      on_complete = function()
        self.commit_editor = nil
        if not self.closed then
          self:refresh()
        end
      end,
    })
  end
  if amend then
    log_backend.head_message(self.root, function(message, err)
      if not message then
        notify(err or "Unable to load the current commit message", vim.log.levels.ERROR)
        return
      end
      open_editor(message)
    end)
  else
    open_editor("")
  end
end

function Session:load_more()
  local panel = self.panels.commits
  if self.active_panel ~= "commits" or not panel.has_more or panel.job then
    return
  end
  panel.request = panel.request + 1
  local request = panel.request
  local existing = #(panel.data or {})
  local load_more_job
  load_more_job = log_backend.list(self.root, {
    limit = self.config.commit_limit,
    skip = existing,
  }, function(items, has_more, err)
    if panel.job == load_more_job then
      panel.job = nil
    end
    if self.closed or request ~= panel.request then
      return
    end
    if not items then
      notify(err or "Unable to load more commits", vim.log.levels.ERROR)
      return
    end
    vim.list_extend(panel.data, items)
    panel.has_more = has_more == true
    self:render_collection("commits", entry_key(panel.entries[panel.selected]))
    self:update_actions()
  end)
  panel.job = load_more_job
end

function Session:run_remote(operation)
  if self.remote_console and self.remote_console.running then
    notify("A remote operation is already running", vim.log.levels.WARN)
    return
  end
  local Console = require("ngit.ui.console")
  local command_labels = {
    fetch = "git fetch --all --prune",
    pull = "git pull --ff-only",
    push = "git push",
  }
  local console = Console.new(command_labels[operation])
  self.remote_console = console
  console.process = remote_backend.run(self.root, operation, function(_, data)
    console:append(data)
  end, function(ok, result)
    console:finish(ok, result.code)
    self:set_result(
      ok and (operation .. " completed") or (operation .. (" failed (%d)"):format(result.code)),
      ok
    )
    if self.remote_console == console then
      self.remote_console = nil
    end
    if ok and not self.closed then
      self:refresh()
    end
  end)
end

function Session:choose_conflict(side)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry or entry.section ~= "conflict" then
    return
  end
  conflict_backend.choose(self.root, entry.file.path, side, function(ok, err)
    self:after_mutation(ok, err)
  end)
end

function Session:run_sequencer(action)
  if not self.operation then
    notify("No merge, rebase, cherry-pick, or revert is in progress", vim.log.levels.WARN)
    return
  end
  local function perform()
    sequencer_backend.run(self.root, self.operation, action, function(ok, err)
      self:after_mutation(ok, err)
    end)
  end
  if action == "abort" then
    vim.ui.select({ "Cancel", "Abort" }, {
      prompt = ("Abort the current %s?"):format(self.operation),
    }, function(choice)
      if choice == "Abort" then
        perform()
      end
    end)
  else
    perform()
  end
end

function Session:start_operation(operation)
  local entry = self:selected_entry()
  local target
  local description
  if operation == "cherry-pick" and entry and entry.kind == "commit" then
    target = entry.commit.oid
    description = ("Cherry-pick %s?"):format(short_oid(target))
  elseif (operation == "merge" or operation == "rebase") and entry and entry.kind == "branch" then
    if entry.branch.current then
      notify("Select a different branch", vim.log.levels.WARN)
      return
    end
    target = entry.branch.oid
    if operation == "merge" then
      description = ("Merge %s into the current branch?"):format(entry.branch.name)
    else
      description = ("Rebase the current branch onto %s?"):format(entry.branch.name)
    end
  else
    return
  end

  vim.ui.select({ "Cancel", "Continue" }, { prompt = description }, function(choice)
    if choice ~= "Continue" then
      return
    end
    sequencer_backend.start(self.root, operation, target, function(ok, err)
      if ok then
        self:refresh()
        return
      end
      sequencer_backend.detect(self.root, function(active)
        if active then
          notify(("%s stopped for conflict resolution"):format(active), vim.log.levels.WARN)
          if self.active_panel == "status" then
            self:refresh()
          else
            self:switch_view("status")
          end
        else
          notify(err or ("Unable to start " .. operation), vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

function Session:help_lines()
  return Help.lines(self.config.mappings)
end

function Session:show_help()
  notify(table.concat(self:help_lines(), "\n"))
end

return Session
