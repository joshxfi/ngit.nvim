local config = require("ngit.config")
local repository = require("ngit.git.repository")
local highlights = require("ngit.ui.highlights")

local M = {}
local active
local opening = false

local function focus(session, view)
  vim.api.nvim_set_current_tabpage(session.tab)
  if view then
    session:switch_view(view)
  end
end

local function start_session(root, opts)
  if active and not active.closed and active.tab and vim.api.nvim_tabpage_is_valid(active.tab) then
    if active.root == root then
      focus(active, opts.view)
      return
    end
    local current_tab = vim.api.nvim_get_current_tabpage()
    active:close()
    if vim.api.nvim_tabpage_is_valid(current_tab) then
      vim.api.nvim_set_current_tabpage(current_tab)
    end
  end

  highlights.setup()
  local Session = require("ngit.ui.session")
  active = Session.new(root)
  active.on_close = function(session)
    if active == session then
      active = nil
    end
  end
  active:open()
  if opts.view and opts.view ~= "status" then
    active:switch_view(opts.view)
  end
end

---@param opts? table
function M.setup(opts)
  return config.setup(opts)
end

---@param opts? { cwd?: string, view?: string, on_ready?: fun(session: table) }
function M.open(opts)
  opts = opts or {}
  if
    not opts.cwd
    and active
    and not active.closed
    and active.tab
    and vim.api.nvim_tabpage_is_valid(active.tab)
  then
    focus(active, opts.view)
    if opts.on_ready then
      opts.on_ready(active)
    end
    return
  end
  if opening then
    return
  end
  opening = true

  repository.discover(opts.cwd, function(root, err)
    opening = false
    if not root then
      vim.notify(err or "Not inside a Git repository", vim.log.levels.ERROR, { title = "ngit" })
      return
    end
    start_session(root, opts)
    if opts.on_ready and active and not active.closed then
      opts.on_ready(active)
    end
  end)
end

--- Entry points that act on a session rather than only opening one.
---
--- The path is resolved before the session exists, because the buffer that names
--- it is the one the user ran the command from and opening ngit replaces it.
---@param path string?
---@return string? absolute
local function absolute_path(path)
  if path and path ~= "" then
    return vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ":p"))
  end
  local name = vim.api.nvim_buf_get_name(0)
  if name == "" or vim.bo.buftype ~= "" then
    return nil
  end
  return vim.fs.normalize(name)
end

---@param root string
---@param absolute string?
---@return string?
local function relative_to(root, absolute)
  if not absolute then
    return nil
  end
  local prefix = root:gsub("/*$", "") .. "/"
  if vim.startswith(absolute, prefix) then
    return absolute:sub(#prefix + 1)
  end
  return nil
end

local function with_session(action)
  M.open({ on_ready = action })
end

--- Opens ngit in review mode. Without a range, this branch is compared with its
--- upstream, which is the question the command exists to answer.
---@param spec string?
function M.review(spec)
  with_session(function(session)
    if spec and spec ~= "" then
      session:set_range(spec)
    else
      session:review_upstream()
    end
  end)
end

---@param path string?
function M.blame(path)
  local absolute = absolute_path(path)
  with_session(function(session)
    local relative = relative_to(session.root, absolute)
    if relative then
      session:blame_path(relative, nil)
    else
      session:blame()
    end
  end)
end

---@param path string?
function M.history(path)
  local absolute = absolute_path(path)
  with_session(function(session)
    local relative = relative_to(session.root, absolute)
    if relative then
      session:set_history(relative)
    else
      session:file_history()
    end
  end)
end

function M.close()
  if active then
    active:close()
  end
end

function M.refresh()
  if active then
    active:refresh()
  end
end

---@return table?
function M._active_session()
  return active
end

return M
