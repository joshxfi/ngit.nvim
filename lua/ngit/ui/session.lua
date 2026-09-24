local config_module = require("ngit.config")
local actions = require("ngit.ui.actions")
local branch_backend = require("ngit.git.branch")
local diff_backend = require("ngit.git.diff")
local log_backend = require("ngit.git.log")
local range_backend = require("ngit.git.range")
local stash_backend = require("ngit.git.stash")
local Dashboard = require("ngit.ui.dashboard")
local DiffView = require("ngit.ui.diff_view")
local Help = require("ngit.ui.help")
local Render = require("ngit.ui.render")
local SessionCommands = require("ngit.ui.session_commands")
local SessionGit = require("ngit.ui.session_git")
local SessionMappings = require("ngit.ui.session_mappings")
local SessionRefresh = require("ngit.ui.session_refresh")
local Lru = require("ngit.util.lru")

local Session = {}
Session.__index = Session

local next_id = 0

local section_order = { "conflict", "staged", "unstaged", "untracked", "range" }
local section_titles = {
  conflict = "Conflicts",
  staged = "Staged",
  unstaged = "Unstaged",
  untracked = "Untracked",
  range = "Range",
}
local section_highlights = {
  conflict = "NgitConflict",
  staged = "NgitStaged",
  unstaged = "NgitUnstaged",
  untracked = "NgitUntracked",
  range = "NgitRange",
}
local section_sign_highlights = {
  conflict = "NgitConflictSign",
  staged = "NgitStagedSign",
  unstaged = "NgitUnstagedSign",
  untracked = "NgitUntrackedSign",
  range = "NgitRangeSign",
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

local function empty_groups()
  return { conflict = {}, staged = {}, unstaged = {}, untracked = {}, range = {} }
end

--- In review mode the Changes panel lists the files a revision range touches
--- instead of the working tree, so it gets a section of its own: the entries have
--- no index or worktree side and no action may treat them as if they did.
local function range_entries(files, filter)
  local groups = empty_groups()
  local needle = filter and filter:lower() or nil
  for _, file in ipairs(files or {}) do
    if not needle or needle == "" or file.path:lower():find(needle, 1, true) then
      groups.range[#groups.range + 1] = { section = "range", file = file }
    end
  end
  return groups
end

local function display_entries(status, filter)
  local groups = empty_groups()
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
  self.cache = Lru.new(self.config.cache_entries, {
    max_weight = self.config.max_cache_bytes,
    weigh = function(diff)
      return diff.estimated_bytes or #(diff.text or "")
    end,
  })
  -- Presentation models cost several times the parsed diff they come from, so
  -- they get a much shallower cache of their own. Holding only the handful of
  -- entries around the cursor is what makes j/k through a file list feel free.
  self.model_cache = Lru.new(4)
  return self
end

function Session:active_state()
  return self.panels[self.active_panel]
end

--- Every index-touching panel action asks this first. A review range has no index
--- side, so answering here is what keeps `s`, `u`, and `X` from producing a
--- confusing git error while the panel is showing someone else's commits.
---@return boolean
function Session:review_only()
  if not self.range then
    return false
  end
  notify(
    ("Reviewing %s. Press %s to return to the working tree."):format(
      self.range.spec,
      self.config.mappings.review or "the review key"
    ),
    vim.log.levels.WARN
  )
  return true
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
  SessionMappings.install(self)
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
        if self.current_diff_models then
          self:render_diff_layout(
            self.diff_layout_override or self.dashboard:desired_preview_layout()
          )
        end
        self:update_actions()
      end
    end,
  })

  if self.config.auto_refresh then
    -- Only writes inside this repository can change its status; refreshing for
    -- every save in the editor spawns Git for nothing.
    local prefix = self.root:gsub("/*$", "") .. "/"
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = self.augroup,
      callback = function(event)
        local name = event.match or ""
        if name ~= "" and not vim.startswith(vim.fs.normalize(name), prefix) then
          return
        end
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
  if self.range_job then
    pcall(self.range_job.kill, self.range_job, 15)
    self.range_job = nil
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
  if self.help_window and vim.api.nvim_win_is_valid(self.help_window) then
    pcall(vim.api.nvim_win_close, self.help_window, true)
  end
  self.help_window = nil
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
    -- Closing the only remaining tab page is an error rather than a no-op, and
    -- the origin tab may already be gone by the time the dashboard is closed.
    if not pcall(vim.cmd, "tabclose") then
      pcall(vim.cmd, "enew")
    end
  end
  if valid_tab(origin) then
    vim.api.nvim_set_current_tabpage(origin)
  end
end

function Session:schedule_refresh(scope)
  SessionRefresh.schedule(self, scope)
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
  local staged_count, unstaged_count = 0, 0
  for _, file in ipairs(self.status and self.status.files or {}) do
    if file.kind ~= "conflict" then
      if status_present(file.index_status) then
        staged_count = staged_count + 1
      end
      if status_present(file.worktree_status) or file.kind == "untracked" then
        unstaged_count = unstaged_count + 1
      end
    end
  end
  local context = {
    panel = self.active_panel,
    entry = panel.entries[panel.selected],
    operation = self.operation,
    has_more = panel.has_more,
    staged_count = staged_count,
    unstaged_count = unstaged_count,
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
  SessionRefresh.full(self)
end

function Session:refresh_status()
  SessionRefresh.status(self)
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
  if not self.dashboard or (not self.status and not self.range) then
    return
  end
  local groups = self.range and range_entries(self.range_files, panel.filter)
    or display_entries(self.status, panel.filter)
  local lines = {}
  local row_entries = {}
  local entries = {}
  local row_highlights = {}

  for _, section in ipairs(section_order) do
    local group = groups[section]
    if #group > 0 then
      if #lines > 0 then
        lines[#lines + 1] = ""
      end
      local heading = Render.section(section_titles[section], #group, section_highlights[section])
      lines[#lines + 1] = heading.text
      for _, span in ipairs(heading.spans) do
        span.row = #lines - 1
        row_highlights[#row_highlights + 1] = span
      end
      for _, entry in ipairs(group) do
        entries[#entries + 1] = entry
        local rendered = Render.status(
          sign_for(self.config, entry),
          display_path(entry),
          section_sign_highlights[entry.section]
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
    local empty
    if panel.filter then
      empty = "  No changes match the current filter."
    elseif self.range then
      empty = ("  %s changes nothing."):format(self.range.spec)
    else
      empty = "  Working tree clean."
    end
    lines = { "", empty }
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
  if self.status and (self.status.ahead > 0 or self.status.behind > 0) then
    suffix = (" ↑%d ↓%d"):format(self.status.ahead, self.status.behind)
  end
  if self.range then
    suffix = suffix .. (" · review %s"):format(self.range.spec)
  end
  if self.operation then
    suffix = suffix .. (" · %s in progress"):format(self.operation)
  end
  if self.config.ignore_whitespace then
    suffix = suffix .. " · -w"
  end
  if self.config.context ~= config_module.defaults().context then
    suffix = suffix .. (" · U%d"):format(self.config.context)
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
    detail = ((self.status and self.status.branch) or "detached") .. suffix,
    highlights = row_highlights,
  })
  if self.active_panel == "status" then
    self:sync_active_aliases()
    self:update_actions()
  end
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
      local rendered = Render.commit(short_oid(item.oid), item.subject, item.decorations)
      line = rendered.text
      entry.highlights = rendered.spans
      searchable =
        table.concat({ item.oid, item.author, item.email, item.subject, item.decorations }, " ")
    elseif view == "branches" then
      entry = { kind = "branch", branch = item }
      local upstream = item.upstream ~= "" and (" → " .. item.upstream .. " " .. item.track) or ""
      local rendered = Render.branch(item.current, item.name, item.subject, upstream, item.remote)
      line = rendered.text
      entry.highlights = rendered.spans
      searchable = table.concat({ item.name, item.upstream, item.subject }, " ")
    else
      entry = { kind = "stash", stash = item }
      local rendered = Render.stash(item.ref, Render.age(item.timestamp), item.subject)
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

--- Diff options are part of the identity of a cached preview: the same file at
--- the same generation looks different once whitespace is ignored or the context
--- width changes, so they belong in the key rather than forcing a cache clear.
function Session:diff_signature()
  return ("%d%s"):format(self.config.context, self.config.ignore_whitespace and "w" or "")
end

function Session:cache_key(entry)
  local signature = self:diff_signature()
  if entry.kind == "commit" then
    return table.concat(
      { "commit", entry.commit.oid, self.history and self.history.path or "" },
      "\0"
    )
  elseif entry.kind == "branch" then
    return table.concat({ "branch", entry.branch.oid }, "\0")
  elseif entry.kind == "stash" then
    return table.concat({ "stash", entry.stash.oid }, "\0")
  elseif entry.section == "range" then
    return table.concat({ "range", self.range.spec, entry.file.path, signature }, "\0")
  end
  return table.concat({
    tostring(self.generation),
    entry.section,
    entry.file.path,
    signature,
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
      -- While following one file's history the patch is narrowed to it, so a
      -- sweeping commit does not bury the file being read.
      preview_job = log_backend.show(
        self.root,
        entry.commit.oid,
        self.config.max_diff_bytes,
        complete,
        self.history and self.history.path or nil
      )
    elseif entry.kind == "branch" then
      preview_job =
        branch_backend.preview(self.root, entry.branch, self.config.max_diff_bytes, complete)
    elseif entry.kind == "stash" then
      preview_job = stash_backend.show(self.root, entry.stash, self.config.max_diff_bytes, complete)
    elseif entry.section == "range" then
      preview_job = range_backend.diff(
        self.root,
        self.range.spec,
        entry.file.path,
        self.config.context,
        self.config.max_diff_bytes,
        complete
      )
    else
      preview_job = diff_backend.load(
        self.root,
        entry.section,
        entry.file.path,
        self.config.context,
        self.config.max_diff_bytes,
        complete,
        { ignore_whitespace = self.config.ignore_whitespace }
      )
    end
    self.diff_job = preview_job
  end, self.config.debounce_ms)
end

function Session:preview_title(entry)
  if entry.kind == "commit" then
    return ("%s · %s"):format(short_oid(entry.commit.oid), entry.commit.subject)
  elseif entry.kind == "branch" then
    local scope = entry.branch.tag and "tag" or "branch"
    return ("%s · %s"):format(scope, entry.branch.name)
  elseif entry.kind == "stash" then
    return ("stash · %s"):format(entry.stash.ref)
  elseif entry.section == "range" then
    return ("%s · %s"):format(self.range.spec, entry.file.path)
  end
  return ("%s · %s"):format(entry.section, entry.file.path)
end

function Session:render_preview(entry, diff)
  self.current_diff = diff
  local opts = { title = self:preview_title(entry), entry = entry }
  local key = self:cache_key(entry)
  local models = self.model_cache:get(key)
  if not models then
    models = { split = DiffView.split(diff, opts), unified = nil }
    self.model_cache:set(key, models)
  end
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
  if layout == "side_by_side" and not self.dashboard:supports_side_by_side() then
    layout = "unified"
    self.diff_layout_override = nil
  end
  if layout == "unified" and not self.current_diff_models.unified then
    self.current_diff_models.unified =
      DiffView.unified(self.current_diff, self.current_diff_opts, self.current_diff_models.split)
  end
  local rendered_layout = self.dashboard:render_diff(
    self.current_diff_models,
    layout,
    DiffView.filetype(self.current_diff)
  )
  self.preview_win = self.dashboard.preview.window
  self.preview_buf = self.dashboard.preview.buffer
  return rendered_layout
end

--- Whether the cursor is in one of the diff windows, whatever they are showing.
---@return boolean
function Session:preview_focused()
  local current = vim.api.nvim_get_current_win()
  for _, item in ipairs(self.dashboard:preview_windows()) do
    if item.window == current then
      return true
    end
  end
  return false
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

--- Presentation model behind the focused pane, which carries the file spans a
--- row has to be traced through.
function Session:preview_model()
  if not self.current_diff_models then
    return nil
  end
  if self.dashboard.preview.layout == "unified" then
    return self.current_diff_models.unified
  end
  return self.current_diff_models.split
end

local visual_modes = { v = true, V = true, ["\22"] = true }

--- Row span an action should act on: the visual selection when one is active,
--- otherwise the cursor's own row.
---
--- Visual mode is left before the caller runs, because every action here
--- re-renders the buffer underneath it and a surviving selection would be drawn
--- against rows that no longer exist.
local function selected_rows(window)
  local mode = vim.api.nvim_get_mode().mode
  if visual_modes[mode:sub(1, 1)] then
    local anchor = vim.fn.line("v")
    local cursor = vim.fn.line(".")
    vim.cmd("normal! \27")
    return math.min(anchor, cursor), math.max(anchor, cursor)
  end
  local row = vim.api.nvim_win_get_cursor(window)[1]
  return row, row
end

function Session:mutation_patch()
  return (self:selection_patch(false))
end

--- Patch for the current preview scope: the whole hunk under the cursor, or just
--- the added and removed rows a visual selection covers.
---
--- `reverse` is not a presentation detail: narrowing a patch to a subset of rows
--- has to know which side the target already holds, so staging and unstaging the
--- same selection produce different patches.
---@param reverse boolean
---@return string? patch, string? err
function Session:selection_patch(reverse)
  local pane, window = self:preview_pane()
  if not pane or not self.current_diff then
    -- Pressed in the diff, a key means "this change". While the preview is still
    -- loading there is no change to point at, and acting on the whole file
    -- instead would turn a hunk discard into a file discard.
    if self:preview_focused() then
      return nil, "The diff is still loading; try again once it is shown"
    end
    return nil, nil
  end
  if self.current_diff.truncated then
    return nil, "Hunk actions are disabled for truncated previews"
  end
  -- A whitespace-ignoring diff prints the collapsed form of a context line, which
  -- is not what the index or the worktree holds, so git cannot place the hunk.
  -- Refusing here is the same call the truncated case makes: the preview is a
  -- reading aid rather than a faithful patch. Whole files still stage.
  if self.config.ignore_whitespace then
    return nil, "Hunk actions are disabled while whitespace is ignored"
  end

  local first, last = selected_rows(window)
  if first == last then
    local unified_start = pane.row_hunks[first]
    if not unified_start then
      return nil, "Move the cursor onto a change, or act on the file from the Changes panel"
    end
    return diff_backend.patch_at_hunk(self.current_diff.lines, unified_start), nil
  end

  local selected = {}
  local count = 0
  for row = first, last do
    local source = pane.unified_rows[row]
    local kind = pane.source_kinds[row]
    if source and (kind == "add" or kind == "delete") then
      selected[source] = true
      count = count + 1
    end
  end
  if count == 0 then
    return nil, "The selection covers no added or removed lines"
  end
  return diff_backend.patch_for_rows(self.current_diff.lines, selected, { reverse = reverse })
end

--- File and source line under the preview cursor, so opening a file from a diff
--- lands where the reader was looking.
---@return string? path, integer? line
function Session:preview_location()
  local pane, window = self:preview_pane()
  local model = self:preview_model()
  if not pane or not model or not valid_window(window) then
    return nil, nil
  end
  local row = vim.api.nvim_win_get_cursor(window)[1]
  local file
  for _, span in ipairs(model.file_spans or {}) do
    if span.row > row then
      break
    end
    file = span.file
  end
  if not file then
    return nil, nil
  end
  -- An old-side number names a line the current file no longer has, so the new
  -- side is preferred whenever the layout has one.
  local number = pane.source_numbers[row]
  if self.dashboard.preview.layout == "side_by_side" then
    number = self.current_diff_models.split.right.source_numbers[row] or number
  end
  return file.new_path or file.old_path, number or nil
end

--- Entries a panel action should act on: every entry a visual selection covers,
--- otherwise just the selected one. Duplicate rows collapse, so a selection that
--- runs across a section heading does not act on a file twice.
---@return table[]
function Session:selected_entries()
  local panel = self:active_state()
  local single = { panel.entries[panel.selected] }
  local ui = self.dashboard and self.dashboard.panels[self.active_panel]
  if not ui or not valid_window(ui.window) or vim.api.nvim_get_current_win() ~= ui.window then
    return single
  end
  local first, last = selected_rows(ui.window)
  if first == last then
    return single
  end
  local entries, seen = {}, {}
  for row = first, last do
    local entry = panel.row_entries[row]
    if entry and not seen[entry] then
      seen[entry] = true
      entries[#entries + 1] = entry
    end
  end
  return #entries > 0 and entries or single
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

--- Brings a commit into view and selects it, so a blame row or a menu can hand
--- the reader back to the history they asked about.
---
--- The commit may be older than the loaded page, in which case the panel pages
--- forward until it appears rather than reporting that it is missing.
---@param oid string
function Session:reveal_commit(oid)
  self:focus_panel("commits")
  local panel = self.panels.commits

  local function select_loaded()
    for index, entry in ipairs(panel.entries) do
      if entry.commit and entry.commit.oid == oid then
        panel.selected = index
        self:sync_active_aliases()
        self:update_file_cursor()
        self:load_preview()
        self:update_actions()
        return true
      end
    end
    return false
  end

  local attempts = 0
  local function advance()
    if self.closed or select_loaded() then
      return
    end
    attempts = attempts + 1
    if not panel.has_more or attempts > 20 then
      notify(("%s is not in the loaded history"):format(oid:sub(1, 8)), vim.log.levels.WARN)
      return
    end
    self:load_more()
    -- load_more replaces the panel job; polling for its completion keeps this
    -- free of a second callback path through the panel loader.
    vim.defer_fn(advance, 60)
  end
  advance()
end

function Session:toggle_diff_layout()
  if not self.current_diff_models or not self.current_diff then
    return
  end
  local requested = self.dashboard.preview.layout == "side_by_side" and "unified" or "side_by_side"
  if requested == "side_by_side" and not self.dashboard:supports_side_by_side() then
    self.diff_layout_override = nil
    notify("Side-by-side diff needs at least 40 preview columns", vim.log.levels.WARN)
    self:render_diff_layout("unified")
    return
  end
  self.diff_layout_override = requested
  self:render_diff_layout(requested)
end

Session.after_mutation = SessionCommands.after_mutation
Session.stage = SessionCommands.stage
Session.unstage = SessionCommands.unstage
Session.stage_all = SessionCommands.stage_all
Session.unstage_all = SessionCommands.unstage_all
Session.discard = SessionCommands.discard
Session.open_file = SessionCommands.open_file
Session.prompt_filter = SessionCommands.prompt_filter
Session.primary_action = SessionCommands.primary_action
Session.new_item = SessionCommands.new_item
Session.delete_item = SessionCommands.delete_item
Session.apply_item = SessionCommands.apply_item
Session.prompt_commit = SessionCommands.prompt_commit
Session.load_more = SessionCommands.load_more
Session.run_remote = SessionCommands.run_remote
Session.run_remote_args = SessionCommands.run_remote_args
Session.choose_conflict = SessionCommands.choose_conflict
Session.run_sequencer = SessionCommands.run_sequencer
Session.start_operation = SessionCommands.start_operation

Session.revert = SessionGit.revert
Session.reset = SessionGit.reset
Session.checkout_commit = SessionGit.checkout_commit
Session.tag = SessionGit.tag
Session.interactive_rebase = SessionGit.interactive_rebase
Session.rename_item = SessionGit.rename_item
Session.set_upstream = SessionGit.set_upstream
Session.remote_menu = SessionGit.remote_menu
Session.stash_menu = SessionGit.stash_menu
Session.commit_menu = SessionGit.commit_menu
Session.file_menu = SessionGit.file_menu
Session.copy_menu = SessionGit.copy_menu
Session.review = SessionGit.review
Session.review_upstream = SessionGit.review_upstream
Session.set_range = SessionGit.set_range
Session.file_history = SessionGit.file_history
Session.set_history = SessionGit.set_history
Session.blame = SessionGit.blame
Session.blame_path = SessionGit.blame_path
Session.repos_menu = SessionGit.repos_menu
Session.toggle_whitespace = SessionGit.toggle_whitespace
Session.adjust_context = SessionGit.adjust_context
Session.jump_conflict = SessionGit.jump_conflict

function Session:help_lines()
  return Help.lines(self.config.mappings)
end

function Session:show_help()
  if self.help_window and vim.api.nvim_win_is_valid(self.help_window) then
    vim.api.nvim_set_current_win(self.help_window)
    return
  end
  local ok, window = pcall(Help.open, self.config.mappings)
  if ok then
    self.help_window = window
  else
    notify(table.concat(self:help_lines(), "\n"))
  end
end

return Session
