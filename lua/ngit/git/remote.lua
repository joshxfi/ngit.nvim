local runner = require("ngit.git.runner")

local M = {}

local operations = {
  fetch = { "fetch", "--all", "--prune", "--progress" },
  pull = { "pull", "--ff-only", "--progress" },
  push = { "push", "--progress" },
}

M.operations = operations

---@param root string
---@param operation "fetch"|"pull"|"push"
---@param on_chunk fun(stream: "stdout"|"stderr", data: string)
---@param callback fun(ok: boolean, result: NgitGitResult)
function M.run(root, operation, on_chunk, callback)
  local args = assert(operations[operation], "unsupported remote operation")
  return runner.run_stream(args, { cwd = root }, on_chunk, function(result)
    callback(runner.ok(result), result)
  end)
end

--- Streams an arbitrary network command, for the variants the menus offer.
---@param root string
---@param args string[]
---@param on_chunk fun(stream: "stdout"|"stderr", data: string)
---@param callback fun(ok: boolean, result: NgitGitResult)
function M.stream(root, args, on_chunk, callback)
  return runner.run_stream(args, { cwd = root }, on_chunk, function(result)
    callback(runner.ok(result), result)
  end)
end

--- Every network variant ngit offers, as the exact argument list it runs. The
--- label is what the console header and the footer report, so the user always
--- sees the command rather than a friendly name for it.
---
--- `--force-with-lease` is the only forcing push here: it refuses when the remote
--- moved since the last fetch, which is the check that separates rewriting your
--- own branch from overwriting someone else's work. Plain `--force` is not
--- offered at all.
M.variants = {
  fetch = {
    { id = "fetch_all", label = "git fetch --all --prune", args = operations.fetch },
    {
      id = "fetch_tags",
      label = "git fetch --all --tags --prune",
      args = { "fetch", "--all", "--tags", "--prune", "--progress" },
    },
    {
      id = "fetch_remote",
      label = "git fetch <remote> --prune",
      remote = true,
      args = function(remote)
        return { "fetch", remote, "--prune", "--progress" }
      end,
    },
  },
  pull = {
    { id = "pull_ff", label = "git pull --ff-only", args = operations.pull },
    {
      id = "pull_rebase",
      label = "git pull --rebase --autostash",
      args = { "pull", "--rebase", "--autostash", "--progress" },
    },
    {
      id = "pull_merge",
      label = "git pull --no-rebase --no-edit",
      args = { "pull", "--no-rebase", "--no-edit", "--progress" },
    },
  },
  push = {
    { id = "push", label = "git push", args = operations.push },
    {
      id = "push_force_lease",
      label = "git push --force-with-lease",
      confirm = "Force-push with lease? The remote must not have moved since the last fetch.",
      args = { "push", "--force-with-lease", "--progress" },
    },
    {
      id = "push_tags",
      label = "git push --tags",
      args = { "push", "--tags", "--progress" },
    },
    {
      id = "push_remote",
      label = "git push <remote> HEAD",
      remote = true,
      args = function(remote)
        return { "push", "--progress", remote, "HEAD" }
      end,
    },
  },
}

---@class NgitRemote
---@field name string
---@field fetch_url string
---@field push_url string

---@param root string
---@param callback fun(remotes: NgitRemote[]?, err: string?)
function M.list(root, callback)
  return runner.run({ "remote", "--verbose" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    local by_name, order = {}, {}
    for _, line in ipairs(vim.split(result.stdout, "\n", { plain = true, trimempty = true })) do
      local name, url, kind = line:match("^(%S+)%s+(.-)%s+%((%a+)%)$")
      if name then
        if not by_name[name] then
          by_name[name] = { name = name, fetch_url = "", push_url = "" }
          order[#order + 1] = by_name[name]
        end
        if kind == "push" then
          by_name[name].push_url = url
        else
          by_name[name].fetch_url = url
        end
      end
    end
    callback(order, nil)
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

---@param root string
---@param name string
---@param url string
---@param callback fun(ok: boolean, err: string?)
function M.add(root, name, url, callback)
  return mutate(root, { "remote", "add", name, url }, callback)
end

---@param root string
---@param from string
---@param to string
---@param callback fun(ok: boolean, err: string?)
function M.rename(root, from, to, callback)
  return mutate(root, { "remote", "rename", from, to }, callback)
end

---@param root string
---@param name string
---@param callback fun(ok: boolean, err: string?)
function M.remove(root, name, callback)
  return mutate(root, { "remote", "remove", name }, callback)
end

--- Turns a remote URL into something a browser can open, so a commit can be
--- linked rather than copied by hand. Only the shapes that are unambiguous are
--- rewritten; anything else is returned untouched for the caller to reject.
---@param url string
---@return string?
function M.browse_url(url)
  if url == nil or url == "" then
    return nil
  end
  local value = url:gsub("%.git$", "")
  local host, path = value:match("^git@([^:]+):(.+)$")
  if host then
    return ("https://%s/%s"):format(host, path)
  end
  host, path = value:match("^ssh://git@([^/]+)/(.+)$")
  if host then
    return ("https://%s/%s"):format(host:gsub(":%d+$", ""), path)
  end
  if vim.startswith(value, "https://") or vim.startswith(value, "http://") then
    return value
  end
  return nil
end

---@param root string
---@param remote string
---@param on_chunk fun(stream: "stdout"|"stderr", data: string)
---@param callback fun(ok: boolean, result: NgitGitResult)
function M.push_set_upstream(root, remote, on_chunk, callback)
  return runner.run_stream(
    { "push", "--progress", "--set-upstream", remote, "HEAD" },
    { cwd = root },
    on_chunk,
    function(result)
      callback(runner.ok(result), result)
    end
  )
end

--- Recognises the one push refusal that only needs an upstream chosen. The
--- streamed console output is the sole copy of stderr, so it is passed back in.
---@param output string
---@return boolean
function M.missing_upstream(output)
  return (output or ""):find("no upstream branch", 1, true) ~= nil
end

---@param root string
---@param callback fun(remote: string?, err: string?)
function M.default_remote(root, callback)
  return runner.run({ "remote" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    local remotes = vim.split(vim.trim(result.stdout), "\n", { plain = true, trimempty = true })
    if #remotes == 0 then
      callback(nil, "This repository has no configured remote")
      return
    end
    for _, name in ipairs(remotes) do
      if name == "origin" then
        callback("origin", nil)
        return
      end
    end
    callback(remotes[1], nil)
  end)
end

return M
