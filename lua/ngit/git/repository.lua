local runner = require("ngit.git.runner")

local M = {}

local function normalize_start(cwd)
  if cwd and cwd ~= "" then
    local stat = vim.uv.fs_stat(cwd)
    if stat and stat.type == "file" then
      return vim.fs.dirname(cwd)
    end
    return cwd
  end

  local name = vim.api.nvim_buf_get_name(0)
  if name ~= "" then
    return vim.fs.dirname(name)
  end
  return vim.uv.cwd()
end

---@param cwd? string
---@param callback fun(root: string?, err: string?)
---@return vim.SystemObj?
function M.discover(cwd, callback)
  local start = normalize_start(cwd)
  return runner.run({ "rev-parse", "--show-toplevel" }, { cwd = start }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(vim.fs.normalize(vim.trim(result.stdout)), nil)
  end)
end

return M

