local diff_parser = require("ngit.git.diff")
local log = require("ngit.git.log")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

-- The peeled object name sits before the symref field on purpose: symref has to
-- stay last so the trailing empty field an ordinary branch produces is the one
-- record parsing drops, while an annotated tag still reports the commit it names
-- rather than the tag object.
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
  "%(*objectname)",
  "",
}, "%00")

---@class NgitBranch
---@field refname string
---@field name string
---@field oid string Commit the ref resolves to, peeled through an annotated tag.
---@field upstream string
---@field track string
---@field timestamp integer
---@field subject string
---@field current boolean
---@field remote boolean
---@field tag boolean
---@field scope "local"|"remote"|"tag"
---@field symbolic boolean

---@param output string
---@return NgitBranch[]
function M.parse(output)
  local branches = {}
  for _, fields in ipairs(records.control_records(output)) do
    if #fields >= 8 then
      local symbolic = (fields[9] or "") ~= ""
      if not symbolic then
        local refname = fields[1]
        local remote = vim.startswith(refname, "refs/remotes/")
        local tag = vim.startswith(refname, "refs/tags/")
        local peeled = fields[10] or ""
        branches[#branches + 1] = {
          refname = refname,
          name = fields[2],
          oid = peeled ~= "" and peeled or fields[3],
          upstream = fields[4],
          track = fields[5],
          timestamp = tonumber(fields[6]) or 0,
          subject = fields[7],
          current = fields[8] == "*",
          remote = remote,
          tag = tag,
          scope = tag and "tag" or (remote and "remote" or "local"),
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
    "refs/tags",
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
  if branch.tag then
    -- A tag names a commit rather than a branch, so checking one out can only
    -- ever detach HEAD.
    return mutate(root, { "checkout", "--detach", branch.refname }, callback)
  end
  local args = { "switch" }
  if branch.remote then
    args[#args + 1] = "--track"
  end
  args[#args + 1] = branch.name
  return mutate(root, args, callback)
end

--- Creates and checks out a branch. `start_point` is optional, and the
--- three-argument form is still accepted so callers that branch from HEAD read
--- unchanged.
---@param root string
---@param name string
---@param start_point? string|fun(ok: boolean, err: string?)
---@param callback? fun(ok: boolean, err: string?)
function M.create(root, name, start_point, callback)
  if type(start_point) == "function" then
    callback = start_point
    start_point = nil
  end
  local args = { "switch", "-c", name }
  if start_point and start_point ~= "" then
    args[#args + 1] = start_point
  end
  return mutate(root, args, callback)
end

function M.delete(root, name, force, callback)
  return mutate(root, { "branch", force and "-D" or "-d", name }, callback)
end

--- Checks out a revision without moving any branch onto it.
---@param root string
---@param revision string
---@param callback fun(ok: boolean, err: string?)
function M.detach(root, revision, callback)
  return mutate(root, { "checkout", "--detach", revision }, callback)
end

---@param root string
---@param from string
---@param to string
---@param callback fun(ok: boolean, err: string?)
function M.rename(root, from, to, callback)
  return mutate(root, { "branch", "-m", from, to }, callback)
end

--- Splits a remote-tracking short name such as `origin/topic` into its parts.
---@param name string
---@return string? remote, string? branch
function M.split_remote(name)
  return name:match("^([^/]+)/(.+)$")
end

--- Deleting a remote branch is a push of an empty ref, so the caller streams it
--- through the same console as the other network operations.
---@param remote string
---@param branch string
---@return string[]
function M.delete_remote_args(remote, branch)
  return { "push", "--progress", "--delete", remote, branch }
end

---@param root string
---@param branch string
---@param upstream string? nil or empty removes the upstream rather than setting one
---@param callback fun(ok: boolean, err: string?)
function M.set_upstream(root, branch, upstream, callback)
  if not upstream or upstream == "" then
    return mutate(root, { "branch", "--unset-upstream", branch }, callback)
  end
  return mutate(root, { "branch", "--set-upstream-to=" .. upstream, branch }, callback)
end

--- Annotated when a message is supplied, lightweight otherwise. The message goes
--- in on stdin so it can carry anything a commit message can.
---@param root string
---@param name string
---@param target? string
---@param message? string
---@param callback fun(ok: boolean, err: string?)
function M.create_tag(root, name, target, message, callback)
  local annotated = message ~= nil and message ~= ""
  local args = { "tag" }
  if annotated then
    args[#args + 1] = "--annotate"
    args[#args + 1] = "--file=-"
  end
  args[#args + 1] = name
  if target and target ~= "" then
    args[#args + 1] = target
  end
  return runner.run(args, {
    cwd = root,
    readonly = false,
    stdin = annotated and (message .. "\n") or nil,
  }, function(result)
    if runner.ok(result) then
      callback(true, nil)
    else
      callback(false, runner.error_message(result))
    end
  end)
end

---@param root string
---@param name string
---@param callback fun(ok: boolean, err: string?)
function M.delete_tag(root, name, callback)
  return mutate(root, { "tag", "--delete", name }, callback)
end

return M
