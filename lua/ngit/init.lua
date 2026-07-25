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

---@param opts? { cwd?: string }
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
