local branch_backend = require("ngit.git.branch")
local log_backend = require("ngit.git.log")
local sequencer_backend = require("ngit.git.sequencer")
local stash_backend = require("ngit.git.stash")
local status_backend = require("ngit.git.status")

local M = {}

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

local function stop(job)
  if job then
    pcall(job.kill, job, 15)
  end
end

local function clear_preview(self, message)
  self.diff_request = self.diff_request + 1
  stop(self.diff_job)
  self.diff_job = nil
  self.current_diff = nil
  self.current_diff_models = nil
  self.current_diff_opts = nil
  if message then
    self.dashboard:render_preview({ "", "  " .. message }, "Changes")
  end
end

function M.schedule(self, scope)
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
        M.status(self)
      else
        M.full(self)
      end
    end
  end, self.config.refresh_debounce_ms)
end

local function load_operation(self, generation, preferred)
  self.operation_request = self.operation_request + 1
  local request = self.operation_request
  stop(self.operation_job)
  self.operation_job = nil
  local job
  job = sequencer_backend.detect(self.root, function(operation)
    if self.operation_job == job then
      self.operation_job = nil
    end
    if
      self.closed
      or request ~= self.operation_request
      or (generation and generation ~= self.refresh_generation)
    then
      return
    end
    self.operation = operation
    if self.status then
      self:render_files(preferred)
    end
    self:update_actions()
  end)
  self.operation_job = job
end

function M.full(self)
  if self.closed then
    return
  end
  self.refresh_generation = self.refresh_generation + 1
  self.generation = self.refresh_generation
  local generation = self.refresh_generation
  self.cache:clear()
  self.model_cache:clear()
  clear_preview(self, "Refreshing repository…")

  local preferred = {}
  for id, panel in pairs(self.panels) do
    preferred[id] = entry_key(panel.entries[panel.selected])
    panel.request = panel.request + 1
    panel.loading = true
    panel.error = nil
    stop(panel.job)
    panel.job = nil
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
  load_operation(self, generation, preferred.status)

  local function load_collection(id, start)
    local panel = self.panels[id]
    local request = panel.request
    local job
    job = start(function(items, has_more, err)
      if panel.job == job then
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
    panel.job = job
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

function M.status(self)
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
  local running_job = panel.job or self.status_job
  stop(running_job)
  if self.status_job and self.status_job ~= running_job then
    stop(self.status_job)
  end
  panel.job = nil
  self.status_job = nil

  if self.active_panel == "status" then
    clear_preview(self, "Refreshing working tree…")
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
  load_operation(self, nil, preferred)
  self:update_actions()
end

return M
