local runner = require("ngit.git.runner")

local M = {}

---@class NgitSubmodule
---@field path string
---@field oid string
---@field describe string
---@field state "current"|"uninitialized"|"modified"|"conflicted"

-- The leading character of each `git submodule status` line is the state, and a
-- space means the recorded commit is checked out.
local states = {
  [" "] = "current",
  ["-"] = "uninitialized",
  ["+"] = "modified",
  ["U"] = "conflicted",
}

---@param output string
---@return NgitSubmodule[]
function M.parse(output)
  local submodules = {}
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    if line ~= "" then
      local marker = line:sub(1, 1)
      local state = states[marker]
      local body = state and line:sub(2) or line
      local oid, rest = body:match("^(%x+) (.+)$")
      if oid then
        local path, describe = rest:match("^(.-) %((.*)%)$")
        submodules[#submodules + 1] = {
          path = path or rest,
          oid = oid,
          describe = describe or "",
          state = state or "current",
        }
      end
    end
  end
  return submodules
end

---@param root string
---@param callback fun(submodules: NgitSubmodule[]?, err: string?)
function M.list(root, callback)
  return runner.run({ "submodule", "status" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---@param root string
---@param callback fun(ok: boolean, err: string?)
function M.update(root, callback)
  return runner.run(
    { "submodule", "update", "--init", "--recursive" },
    { cwd = root, readonly = false },
    function(result)
      if runner.ok(result) then
        callback(true, nil)
      else
        callback(false, runner.error_message(result))
      end
    end
  )
end

return M
