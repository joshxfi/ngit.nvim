local diff_parser = require("ngit.git.diff")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

local format = table.concat({
  "%x1e%H",
  "%P",
  "%an",
  "%ae",
  "%at",
  "%D",
  "%s",
  "",
}, "%x00")

---@class NgitCommit
---@field oid string
---@field parents string[]
---@field author string
---@field email string
---@field timestamp integer
---@field decorations string
---@field subject string

---@param output string
---@return NgitCommit[]
function M.parse(output)
  local commits = {}
  for _, fields in ipairs(records.control_records(output)) do
    if #fields >= 7 then
      commits[#commits + 1] = {
        oid = fields[1],
        parents = vim.split(fields[2], " ", { plain = true, trimempty = true }),
        author = fields[3],
        email = fields[4],
        timestamp = tonumber(fields[5]) or 0,
        decorations = fields[6],
        subject = fields[7],
      }
    end
  end
  return commits
end

---@param root string
---@param opts? { limit?: integer, skip?: integer, revision?: string }
---@param callback fun(commits: NgitCommit[]?, has_more: boolean?, err: string?)
function M.list(root, opts, callback)
  opts = opts or {}
  local limit = opts.limit or 150
  local args = {
    "log",
    "--no-color",
    "--date-order",
    ("--max-count=%d"):format(limit + 1),
    ("--skip=%d"):format(opts.skip or 0),
    "--decorate=full",
    "--pretty=format:" .. format,
  }
  if opts.revision then
    args[#args + 1] = opts.revision
  end
  return runner.run(args, { cwd = root }, function(result)
    if not runner.ok(result) then
      local unborn = result.code == 128
        and (
          result.stderr:find("does not have any commits yet", 1, true)
          or result.stderr:find("unknown revision", 1, true)
        )
      if unborn then
        callback({}, false, nil)
        return
      end
      callback(nil, nil, runner.error_message(result))
      return
    end
    local commits = M.parse(result.stdout)
    local has_more = #commits > limit
    if has_more then
      table.remove(commits)
    end
    callback(commits, has_more, nil)
  end)
end

---@param root string
---@param oid string
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
function M.show(root, oid, max_bytes, callback)
  local args = {
    "show",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--stat",
    "--patch",
    -- "fuller" repeats the author as committer on all but rebased or amended
    -- commits, spending two of the preview's first lines to say nothing.
    "--format=medium",
    "--max-count=1",
    oid,
  }
  return runner.run(args, { cwd = root, max_stdout_bytes = max_bytes }, function(result)
    if not result.truncated and not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(diff_parser.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

---@param root string
---@param callback fun(message: string?, err: string?)
function M.head_message(root, callback)
  return runner.run({ "log", "-1", "--format=%B" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(result.stdout:gsub("%s+$", ""), nil)
  end)
end

return M
