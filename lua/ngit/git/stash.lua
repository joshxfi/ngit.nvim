local diff_parser = require("ngit.git.diff")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

local format = table.concat({ "%x1e%gd", "%H", "%at", "%gs", "" }, "%x00")

---@class NgitStash
---@field ref string
---@field oid string
---@field timestamp integer
---@field subject string

function M.parse(output)
  local stashes = {}
  for _, fields in ipairs(records.control_records(output)) do
    if #fields >= 4 then
      stashes[#stashes + 1] = {
        ref = fields[1],
        oid = fields[2],
        timestamp = tonumber(fields[3]) or 0,
        subject = fields[4],
      }
    end
  end
  return stashes
end

function M.list(root, callback)
  return runner.run({ "stash", "list", "--format=" .. format }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout), nil)
  end)
end

function M.show(root, stash, max_bytes, callback)
  return runner.run({
    "stash",
    "show",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--stat",
    "--patch",
    stash.ref,
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

function M.push(root, message, callback)
  local args = { "stash", "push", "--include-untracked" }
  if message and message ~= "" then
    args[#args + 1] = "--message"
    args[#args + 1] = message
  end
  return mutate(root, args, callback)
end

function M.apply(root, stash, callback)
  return mutate(root, { "stash", "apply", stash.ref }, callback)
end

function M.pop(root, stash, callback)
  return mutate(root, { "stash", "pop", stash.ref }, callback)
end

function M.drop(root, stash, callback)
  return mutate(root, { "stash", "drop", stash.ref }, callback)
end

return M
