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

--- Applies a generated patch to the target the caller names.
---
--- `--recount` is what lets a narrowed patch be trusted: the row counts in a
--- hunk header no longer have to match after rows have been dropped or turned
--- into context, and git recomputes them from the body instead.
---@param root string
---@param patch string
---@param opts { reverse?: boolean, target?: "index"|"worktree"|"both" }
---@param callback fun(ok: boolean, err: string?)
function M.apply(root, patch, opts, callback)
  local args = { "apply", "--recount", "--whitespace=nowarn" }
  local target = opts.target or "index"
  if target == "index" then
    args[#args + 1] = "--cached"
  elseif target == "both" then
    args[#args + 1] = "--index"
  end
  if opts.reverse then
    args[#args + 1] = "--reverse"
  end
  args[#args + 1] = "-"
  return runner.run(args, { cwd = root, readonly = false, stdin = patch }, done(callback))
end

---@param root string
---@param patch string
---@param reverse boolean
---@param callback fun(ok: boolean, err: string?)
function M.apply_cached(root, patch, reverse, callback)
  return M.apply(root, patch, { reverse = reverse, target = "index" }, callback)
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
---@param paths string|string[]
---@param callback fun(ok: boolean, err: string?)
function M.remove_untracked(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "clean", "--force", "-d" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

---@class NgitCommitOptions
---@field amend? boolean
---@field signoff? boolean
---@field no_verify? boolean
---@field gpg_sign? boolean
---@field allow_empty? boolean
---@field no_edit? boolean Keep the recorded message rather than the supplied one.
---@field fixup? string Commit that this one should be squashed into silently.
---@field squash? string Commit that this one should be squashed into, keeping both messages.

--- `amend` accepts a bare boolean so the plain commit and amend paths read as
--- before; the table form carries the switches the options menu offers.
---@param root string
---@param message string
---@param amend boolean|NgitCommitOptions
---@param callback fun(ok: boolean, err: string?)
function M.commit(root, message, amend, callback)
  local opts = type(amend) == "table" and amend or { amend = amend == true }
  local args = { "commit" }
  if opts.amend then
    args[#args + 1] = "--amend"
  end
  if opts.signoff then
    args[#args + 1] = "--signoff"
  end
  if opts.no_verify then
    args[#args + 1] = "--no-verify"
  end
  if opts.gpg_sign then
    args[#args + 1] = "--gpg-sign"
  end
  if opts.allow_empty then
    args[#args + 1] = "--allow-empty"
  end

  local stdin
  if opts.fixup then
    args[#args + 1] = "--fixup=" .. opts.fixup
  elseif opts.squash then
    args[#args + 1] = "--squash=" .. opts.squash
    args[#args + 1] = "--no-edit"
  elseif opts.no_edit or (opts.amend and message == "") then
    args[#args + 1] = "--no-edit"
  else
    args[#args + 1] = "--file=-"
    stdin = message .. "\n"
  end
  return runner.run(args, { cwd = root, readonly = false, stdin = stdin }, done(callback))
end

---@param root string
---@param mode "soft"|"mixed"|"hard"|"keep"
---@param target string
---@param callback fun(ok: boolean, err: string?)
function M.reset(root, mode, target, callback)
  return runner.run(
    { "reset", "--" .. mode, target },
    { cwd = root, readonly = false },
    done(callback)
  )
end

--- Stops tracking a path while leaving it on disk.
---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.untrack(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "rm", "--cached", "-r", "--quiet" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

---@param root string
---@param from string
---@param to string
---@param callback fun(ok: boolean, err: string?)
function M.move(root, from, to, callback)
  return runner.run({ "mv", "--", from, to }, { cwd = root, readonly = false }, done(callback))
end

--- Records a path in the index with empty content, so an untracked file starts
--- producing diffs instead of hiding its whole body behind one status line.
---@param root string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.intent_to_add(root, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "add", "--intent-to-add" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

--- Restores paths from an arbitrary commit into the index and the worktree.
---@param root string
---@param revision string
---@param paths string[]
---@param callback fun(ok: boolean, err: string?)
function M.restore_from(root, revision, paths, callback)
  paths = type(paths) == "string" and { paths } or paths
  return runner.run(
    with_paths({ "restore", "--source=" .. revision, "--staged", "--worktree" }, paths),
    { cwd = root, readonly = false },
    done(callback)
  )
end

return M
