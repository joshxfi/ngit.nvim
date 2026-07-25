local runner = require("ngit.git.runner")

local M = {}

local operations = {
  fetch = { "fetch", "--all", "--prune", "--progress" },
  pull = { "pull", "--ff-only", "--progress" },
  push = { "push", "--progress" },
}

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
