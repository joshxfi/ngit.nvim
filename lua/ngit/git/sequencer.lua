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
  revert = function(target)
    return { "-c", "core.editor=true", "revert", "--no-edit", target }
  end,
}

---@param root string
---@param operation "merge"|"rebase"|"cherry-pick"|"revert"
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

---@class NgitRebaseStep
---@field action "pick"|"reword"|"edit"|"squash"|"fixup"|"drop"
---@field oid string
---@field subject string

--- Commits an interactive rebase onto `base` would replay, oldest first, which is
--- the order the todo list uses.
---@param root string
---@param base string
---@param callback fun(steps: NgitRebaseStep[]?, err: string?)
function M.rebase_todo(root, base, callback)
  return runner.run({
    "log",
    "--reverse",
    "--no-merges",
    "--format=%H%x00%s",
    base .. "..HEAD",
  }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    local steps = {}
    for _, line in ipairs(vim.split(result.stdout, "\n", { plain = true })) do
      if line ~= "" then
        local oid, subject = line:match("^([^%z]+)%z(.*)$")
        if oid then
          steps[#steps + 1] = { action = "pick", oid = oid, subject = subject }
        end
      end
    end
    callback(steps, nil)
  end)
end

--- Git invokes the sequence editor through its own shell as `$EDITOR <todo>`, so
--- any command that writes the file works. Copying a prepared todo over it is
--- what lets ngit own the list without ever handing a buffer to a subprocess.
local function shell_quote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

--- Translates a plan into todo lines.
---
--- `reword` has no todo verb that carries a new message, and pointing GIT_EDITOR
--- at a real editor from inside an asynchronous job is not something this plugin
--- can do safely. A reword therefore becomes a pick followed by `break`: the
--- rebase stops with that commit at HEAD, where amending it is the ordinary
--- amend action and `continue` resumes.
---@param steps NgitRebaseStep[]
---@return string[]
function M.todo_lines(steps)
  local lines = {}
  for _, step in ipairs(steps) do
    if step.action == "drop" then
      lines[#lines + 1] = ("drop %s %s"):format(step.oid, step.subject)
    elseif step.action == "reword" then
      lines[#lines + 1] = ("pick %s %s"):format(step.oid, step.subject)
      lines[#lines + 1] = "break"
    else
      lines[#lines + 1] = ("%s %s %s"):format(step.action, step.oid, step.subject)
    end
  end
  return lines
end

---@param root string
---@param base string
---@param steps NgitRebaseStep[]
---@param callback fun(ok: boolean, err: string?)
function M.rebase_with_todo(root, base, steps, callback)
  local lines = M.todo_lines(steps)
  if #lines == 0 then
    callback(false, "The rebase plan is empty")
    return nil
  end
  local path = vim.fn.tempname()
  if vim.fn.writefile(lines, path) ~= 0 then
    callback(false, "Unable to write the rebase plan")
    return nil
  end
  return runner.run({ "rebase", "--interactive", base }, {
    cwd = root,
    readonly = false,
    env = {
      GIT_SEQUENCE_EDITOR = "cp -- " .. shell_quote(path),
      -- A squash keeps git's combined message rather than opening an editor the
      -- job cannot drive; the result is amendable straight afterwards.
      GIT_EDITOR = "true",
    },
  }, function(result)
    pcall(vim.uv.fs_unlink, path)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

--- Replays `base..HEAD` letting git build the todo itself, so `fixup!` and
--- `squash!` subjects fold into the commits they name.
---@param root string
---@param base string
---@param callback fun(ok: boolean, err: string?)
function M.rebase_autosquash(root, base, callback)
  return runner.run({ "rebase", "--interactive", "--autosquash", base }, {
    cwd = root,
    readonly = false,
    env = { GIT_SEQUENCE_EDITOR = "true", GIT_EDITOR = "true" },
  }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

return M
