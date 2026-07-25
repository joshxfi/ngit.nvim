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

-- Renames occupy two index slots, so every path-scoped mutation has to name the
-- old path as well or the untouched half is left behind as a phantom entry.
local function with_paths(args, paths)
  args[#args + 1] = "--"
  for _, path in ipairs(paths) do
    if path and path ~= "" then
      args[#args + 1] = path
    end
  end
  return args
end

---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.stage_file(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(with_paths({ "add" }, paths), { cwd = root, readonly = false }, done(callback))
end

---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.unstage_file(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "reset", "--quiet" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

---@param root string
---@param callback fun(ok: boolean, err: string?)
function M.stage_all(root, callback)
  return runner.run({ "add", "--all", "--", "." }, { cwd = root, readonly = false }, done(callback))
end

---@param root string
---@param callback fun(ok: boolean, err: string?)
function M.unstage_all(root, callback)
  return runner.run({ "reset", "--quiet", "--" }, { cwd = root, readonly = false }, done(callback))
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
  return runner.run(args, { cwd = root, readonly = false, stdin = patch }, done(callback))
end

---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.discard_file(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "restore", "--worktree" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

--- Resets both the index and the worktree back to HEAD. A staged addition is
--- removed from disk, and a staged rename is returned to its original name.
---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.discard_all_changes(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "restore", "--staged", "--worktree" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

---@param root string
---@param path string
---@param callback fun(ok: boolean, err: string?)
function M.remove_untracked(root, path, callback)
  return runner.run(
    { "clean", "--force", "-d", "--", path },
    { cwd = root, readonly = false },
    done(callback)
  )
end

---@param root string
---@param message string
---@param amend boolean
---@param callback fun(ok: boolean, err: string?)
function M.commit(root, message, amend, callback)
  local args = { "commit" }
  if amend then
    args[#args + 1] = "--amend"
  end
  local stdin
  if amend and message == "" then
    args[#args + 1] = "--no-edit"
  else
    args[#args + 1] = "--file=-"
    stdin = message .. "\n"
  end
  return runner.run(args, { cwd = root, readonly = false, stdin = stdin }, done(callback))
end

return M
