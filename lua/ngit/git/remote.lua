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

return M
