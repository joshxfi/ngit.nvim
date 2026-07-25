local runner = require("ngit.git.runner")

local M = {}

local markers = {
  { "rebase", "rebase-merge", "directory" },
  { "rebase", "rebase-apply", "directory" },
  { "cherry-pick", "CHERRY_PICK_HEAD", "file" },
  { "revert", "REVERT_HEAD", "file" },
  { "merge", "MERGE_HEAD", "file" },
}

local function exists(path, kind)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == kind
end

local function scan(git_dir)
  for _, marker in ipairs(markers) do
    if exists(vim.fs.joinpath(git_dir, marker[2]), marker[3]) then
      return marker[1]
    end
  end
  return nil
end

-- A worktree's git directory is fixed for the life of that worktree, so the
-- lookup runs once instead of spawning rev-parse on every refresh. Detection
-- then costs a few stat calls and needs no subprocess at all.
local git_dirs = {}

---@param root string
function M.forget(root)
  git_dirs[root] = nil
end

---@param root string
---@param callback fun(operation: string?, err: string?)
---@return vim.SystemObj?
function M.detect(root, callback)
  local cached = git_dirs[root]
  if cached then
    local operation = scan(cached)
    vim.schedule(function()
      callback(operation, nil)
    end)
    return nil
  end
  return runner.run({ "rev-parse", "--absolute-git-dir" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    local git_dir = vim.trim(result.stdout)
    git_dirs[root] = git_dir
    callback(scan(git_dir), nil)
  end)
end

local commands = {
  ["merge:continue"] = { "-c", "core.editor=true", "merge", "--continue" },
  ["merge:abort"] = { "merge", "--abort" },
  ["rebase:continue"] = { "-c", "core.editor=true", "rebase", "--continue" },
  ["rebase:abort"] = { "rebase", "--abort" },
  ["cherry-pick:continue"] = { "-c", "core.editor=true", "cherry-pick", "--continue" },
  ["cherry-pick:abort"] = { "cherry-pick", "--abort" },
  ["revert:continue"] = { "-c", "core.editor=true", "revert", "--continue" },
  ["revert:abort"] = { "revert", "--abort" },
}

---@param root string
---@param operation string
---@param action "continue"|"abort"
---@param callback fun(ok: boolean, err: string?)
function M.run(root, operation, action, callback)
  local args = commands[operation .. ":" .. action]
  if not args then
    callback(false, ("Unsupported Git operation: %s"):format(operation))
    return
  end
  return runner.run(args, { cwd = root, readonly = false }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

local start_commands = {
  merge = function(target)
    return { "-c", "core.editor=true", "merge", "--no-edit", target }
  end,
  rebase = function(target)
    return { "-c", "core.editor=true", "rebase", target }
  end,
  ["cherry-pick"] = function(target)
    return { "-c", "core.editor=true", "cherry-pick", target }
  end,
}

---@param root string
---@param operation "merge"|"rebase"|"cherry-pick"
---@param target string
---@param callback fun(ok: boolean, err: string?)
function M.start(root, operation, target, callback)
  local factory = start_commands[operation]
  if not factory then
    callback(false, ("Unsupported Git operation: %s"):format(operation))
    return
  end
  return runner.run(factory(target), { cwd = root, readonly = false }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

return M
