local diff_parser = require("ngit.git.diff")
local log = require("ngit.git.log")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

local format = table.concat({
  "%1e%(refname)",
  "%(refname:short)",
  "%(objectname)",
  "%(upstream:short)",
  "%(upstream:track)",
  "%(committerdate:unix)",
  "%(subject)",
  "%(HEAD)",
  "%(symref)",
  "",
}, "%00")

---@class NgitBranch
---@field refname string
---@field name string
---@field oid string
---@field upstream string
---@field track string
---@field timestamp integer
---@field subject string
---@field current boolean
---@field remote boolean
---@field symbolic boolean

---@param output string
---@return NgitBranch[]
function M.parse(output)
  local branches = {}
  for _, fields in ipairs(records.control_records(output)) do
    if #fields >= 8 then
      local symbolic = (fields[9] or "") ~= ""
      if not symbolic then
        branches[#branches + 1] = {
          refname = fields[1],
          name = fields[2],
          oid = fields[3],
          upstream = fields[4],
          track = fields[5],
          timestamp = tonumber(fields[6]) or 0,
          subject = fields[7],
          current = fields[8] == "*",
          remote = vim.startswith(fields[1], "refs/remotes/"),
          symbolic = false,
        }
      end
    end
  end
  return branches
end

---@param root string
---@param callback fun(branches: NgitBranch[]?, err: string?)
function M.list(root, callback)
  return runner.run({
    "for-each-ref",
    "--sort=-committerdate",
    "--format=" .. format,
    "refs/heads",
    "refs/remotes",
  }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---@param root string
---@param branch NgitBranch
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
function M.preview(root, branch, max_bytes, callback)
  if branch.current then
    return log.show(root, branch.oid, max_bytes, callback)
  end
  return runner.run({
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--stat",
    "--patch",
    "HEAD..." .. branch.oid,
  }, { cwd = root, max_stdout_bytes = max_bytes }, function(result)
    if not result.truncated and not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(diff_parser.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

local function mutate(root, args, callback)
  return runner.run(args, { cwd = root, readonly = false }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

function M.switch(root, branch, callback)
  local args = { "switch" }
  if branch.remote then
    args[#args + 1] = "--track"
  end
  args[#args + 1] = branch.name
  return mutate(root, args, callback)
end

function M.create(root, name, callback)
  return mutate(root, { "switch", "-c", name }, callback)
end

function M.delete(root, name, force, callback)
  return mutate(root, { "branch", force and "-D" or "-d", name }, callback)
end

return M
