local runner = require("ngit.git.runner")

local M = {}

---@class NgitFile
---@field path string
---@field old_path? string
---@field index_status string
---@field worktree_status string
---@field submodule string
---@field kind string
---@field score? string

---@class NgitStatus
---@field branch string
---@field oid string?
---@field upstream string?
---@field ahead integer
---@field behind integer
---@field stash_count integer
---@field files NgitFile[]

local kinds = {
  M = "modified",
  T = "type_changed",
  A = "added",
  D = "deleted",
  R = "renamed",
  C = "copied",
  U = "unmerged",
  ["?"] = "untracked",
}

local function parse_xy(xy)
  return xy:sub(1, 1), xy:sub(2, 2)
end

local function kind_for(index_status, worktree_status, fallback)
  if fallback then
    return fallback
  end
  if index_status == "U" or worktree_status == "U" then
    return "conflict"
  end
  return kinds[worktree_status] or kinds[index_status] or "modified"
end

local function tokens(output)
  local result = {}
  local start = 1
  while start <= #output do
    local stop = output:find("\0", start, true)
    if not stop then
      local tail = output:sub(start)
      if tail ~= "" then
        result[#result + 1] = tail
      end
      break
    end
    result[#result + 1] = output:sub(start, stop - 1)
    start = stop + 1
  end
  return result
end

---@param output string
---@return NgitStatus
function M.parse(output)
  local status = {
    branch = "(unknown)",
    oid = nil,
    upstream = nil,
    ahead = 0,
    behind = 0,
    stash_count = 0,
    files = {},
  }

  local records = tokens(output)
  local index = 1
  while index <= #records do
    local record = records[index]

    if vim.startswith(record, "# branch.oid ") then
      status.oid = record:sub(14)
    elseif vim.startswith(record, "# branch.head ") then
      status.branch = record:sub(15)
    elseif vim.startswith(record, "# branch.upstream ") then
      status.upstream = record:sub(19)
    elseif vim.startswith(record, "# branch.ab ") then
      local ahead, behind = record:match("^# branch%.ab %+([0-9]+) %-([0-9]+)$")
      status.ahead = tonumber(ahead) or 0
      status.behind = tonumber(behind) or 0
    elseif vim.startswith(record, "# stash ") then
      status.stash_count = tonumber(record:sub(9)) or 0
    elseif vim.startswith(record, "1 ") then
      local xy, submodule, path =
        record:match("^1 ([^ ]+) ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$")
      if xy and path then
        local x, y = parse_xy(xy)
        status.files[#status.files + 1] = {
          path = path,
          index_status = x,
          worktree_status = y,
          submodule = submodule,
          kind = kind_for(x, y),
        }
      end
    elseif vim.startswith(record, "2 ") then
      local xy, submodule, score, path =
        record:match("^2 ([^ ]+) ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ ([^ ]+) (.*)$")
      if xy and path then
        local x, y = parse_xy(xy)
        status.files[#status.files + 1] = {
          path = path,
          old_path = records[index + 1],
          index_status = x,
          worktree_status = y,
          submodule = submodule,
          kind = kind_for(x, y, "renamed"),
          score = score,
        }
        index = index + 1
      end
    elseif vim.startswith(record, "u ") then
      local xy, submodule, path =
        record:match("^u ([^ ]+) ([^ ]+) [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ (.*)$")
      if xy and path then
        local x, y = parse_xy(xy)
        status.files[#status.files + 1] = {
          path = path,
          index_status = x,
          worktree_status = y,
          submodule = submodule,
          kind = "conflict",
        }
      end
    elseif vim.startswith(record, "? ") then
      status.files[#status.files + 1] = {
        path = record:sub(3),
        index_status = "?",
        worktree_status = "?",
        submodule = "N...",
        kind = "untracked",
      }
    end

    index = index + 1
  end

  table.sort(status.files, function(a, b)
    return a.path < b.path
  end)
  return status
end

---@param root string
---@param callback fun(status: NgitStatus?, err: string?)
---@return vim.SystemObj?
function M.load(root, callback)
  return runner.run(
    { "status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all" },
    { cwd = root },
    function(result)
      if not runner.ok(result) then
        callback(nil, runner.error_message(result))
        return
      end
      callback(M.parse(result.stdout), nil)
    end
  )
end

return M
