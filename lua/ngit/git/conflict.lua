local mutate = require("ngit.git.mutate")
local runner = require("ngit.git.runner")

local M = {}

---@param root string
---@param path string
---@param side "ours"|"theirs"
---@param callback fun(ok: boolean, err: string?)
function M.choose(root, path, side, callback)
  runner.run(
    { "checkout", "--" .. side, "--", path },
    { cwd = root, readonly = false },
    function(result)
      if not runner.ok(result) then
        callback(false, runner.error_message(result))
        return
      end
      mutate.stage_file(root, path, callback)
    end
  )
end

return M
