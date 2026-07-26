local runner = require("ngit.git.runner")

local M = {}

---@class NgitWorktree
---@field path string
---@field head string
---@field branch string
---@field bare boolean
---@field detached boolean
---@field locked boolean

--- Parses `git worktree list --porcelain`, where a blank line ends each record.
---@param output string
---@return NgitWorktree[]
function M.parse(output)
  local worktrees = {}
  local current
  local function flush()
    if current and current.path ~= "" then
      worktrees[#worktrees + 1] = current
    end
    current = nil
  end
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    if line == "" then
      flush()
    else
      local key, value = line:match("^(%S+) ?(.*)$")
      if key == "worktree" then
        flush()
        current = {
          path = value,
          head = "",
          branch = "",
          bare = false,
          detached = false,
          locked = false,
        }
      elseif current then
        if key == "HEAD" then
          current.head = value
        elseif key == "branch" then
          current.branch = value:gsub("^refs/heads/", "")
        elseif key == "bare" then
          current.bare = true
        elseif key == "detached" then
          current.detached = true
        elseif key == "locked" then
          current.locked = true
        end
      end
    end
  end
  flush()
  return worktrees
end

---@param root string
---@param callback fun(worktrees: NgitWorktree[]?, err: string?)
function M.list(root, callback)
  return runner.run({ "worktree", "list", "--porcelain" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---@param root string
---@param path string
---@param branch string? creates and checks out this branch in the new worktree
---@param callback fun(ok: boolean, err: string?)
function M.add(root, path, branch, callback)
  local args = { "worktree", "add" }
  if branch and branch ~= "" then
    args[#args + 1] = "-b"
    args[#args + 1] = branch
  end
  args[#args + 1] = path
  return runner.run(args, { cwd = root, readonly = false }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

---@param root string
---@param path string
---@param callback fun(ok: boolean, err: string?)
function M.remove(root, path, callback)
  return runner.run(
    { "worktree", "remove", path },
    { cwd = root, readonly = false },
    function(result)
      if runner.ok(result) then
        callback(true, nil)
      else
        callback(false, runner.error_message(result))
      end
    end
  )
end

return M
