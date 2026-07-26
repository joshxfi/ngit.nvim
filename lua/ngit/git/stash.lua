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

--- `git stash push` builds an internal `:/` pathspec, which `--literal-pathspecs`
--- makes git reject, so stash mutations opt out of the flag and mark any path they
--- pass with `:(literal)` instead.
local function mutate(root, args, callback)
  return runner.run(
    args,
    { cwd = root, readonly = false, literal_pathspecs = false },
    function(result)
      if runner.ok(result) then
        callback(true, nil)
      else
        callback(false, runner.error_message(result))
      end
    end
  )
end

---@class NgitStashOptions
---@field keep_index? boolean Leave the staged content in place after stashing.
---@field staged? boolean Stash only what is staged.
---@field paths? string[] Restrict the stash to these paths.

--- `opts` is optional, so the two-argument form that stashes everything reads
--- unchanged. `--staged` and `--include-untracked` are mutually exclusive in git,
--- and asking for both is a request for the staged half only.
---@param root string
---@param message string?
---@param opts? NgitStashOptions|fun(ok: boolean, err: string?)
---@param callback? fun(ok: boolean, err: string?)
function M.push(root, message, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  opts = opts or {}
  local args = { "stash", "push" }
  if opts.staged then
    args[#args + 1] = "--staged"
  else
    args[#args + 1] = "--include-untracked"
    if opts.keep_index then
      args[#args + 1] = "--keep-index"
    end
  end
  if message and message ~= "" then
    args[#args + 1] = "--message"
    args[#args + 1] = message
  end
  if opts.paths and #opts.paths > 0 then
    args[#args + 1] = "--"
    for _, path in ipairs(opts.paths) do
      args[#args + 1] = runner.literal(path)
    end
  end
  return mutate(root, args, callback)
end

--- `--index` restores the staged/unstaged split the stash was taken with, which
--- is the difference between resuming work and having to stage it all again.
---@param root string
---@param stash NgitStash
---@param opts? { index?: boolean }|fun(ok: boolean, err: string?)
---@param callback? fun(ok: boolean, err: string?)
function M.apply(root, stash, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  local args = { "stash", "apply" }
  if opts and opts.index then
    args[#args + 1] = "--index"
  end
  args[#args + 1] = stash.ref
  return mutate(root, args, callback)
end

function M.pop(root, stash, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  local args = { "stash", "pop" }
  if opts and opts.index then
    args[#args + 1] = "--index"
  end
  args[#args + 1] = stash.ref
  return mutate(root, args, callback)
end

function M.drop(root, stash, callback)
  return mutate(root, { "stash", "drop", stash.ref }, callback)
end

--- Creates a branch at the commit the stash was taken from and applies the stash
--- there, which is how a stash that no longer applies cleanly gets rescued.
---@param root string
---@param name string
---@param stash NgitStash
---@param callback fun(ok: boolean, err: string?)
function M.branch(root, name, stash, callback)
  return mutate(root, { "stash", "branch", name, stash.ref }, callback)
end

return M
