local M = {}

--- Runs asynchronous steps in order and stops at the first failure.
---
--- Every mutation in ngit reports through a `fun(ok, err)` continuation, so an
--- action that needs two Git commands - resolve then stage, delete then prune -
--- would otherwise nest them by hand and lose the error of whichever one failed.
---@param steps fun(done: fun(ok: boolean, err: string?))[]
---@param callback fun(ok: boolean, err: string?)
function M.run(steps, callback)
  local index = 0
  local function advance(ok, err)
    if not ok then
      callback(false, err)
      return
    end
    index = index + 1
    local step = steps[index]
    if not step then
      callback(true, nil)
      return
    end
    step(advance)
  end
  advance(true, nil)
end

return M
