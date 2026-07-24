local runner = require("ngit.git.runner")

local M = {}

local function done(callback)
  return function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end
end

---@param root string
---@param path string
---@param callback fun(ok: boolean, err: string?)
function M.stage_file(root, path, callback)
  return runner.run({ "add", "--", path }, { cwd = root, readonly = false }, done(callback))
end

---@param root string
---@param patch string
---@param reverse boolean
---@param callback fun(ok: boolean, err: string?)
function M.apply_cached(root, patch, reverse, callback)
  local args = { "apply", "--cached", "--recount", "--whitespace=nowarn" }
  if reverse then
    args[#args + 1] = "--reverse"
  end
  args[#args + 1] = "-"
  return runner.run(
    args,
    { cwd = root, readonly = false, stdin = patch },
    done(callback)
  )
end

---@param root string
---@param path string
---@param callback fun(ok: boolean, err: string?)
function M.discard_file(root, path, callback)
  return runner.run(
    { "restore", "--worktree", "--", path },
    { cwd = root, readonly = false },
    done(callback)
  )
end

return M

