--- Source-line gutter for diff preview buffers.
---
--- The numbers used to be one inline virtual-text extmark per line, which cost
--- an extmark for every row of the diff whether or not it was ever displayed.
--- 'statuscolumn' asks for the same text only for rows the screen actually
--- draws, so a large patch no longer pays for its off-screen body, and the
--- numbers stay pinned when the diff is scrolled horizontally.
local M = {}

-- Keyed by buffer handle, so entries are released by detach() rather than by
-- the collector; the dashboard detaches on every re-render and on disposal.
local models = {}

--- Width of "%5d" plus the marker column and its surrounding spaces.
local width = 8
local blank = string.rep(" ", width)

M.expression = "%!v:lua.require'ngit.ui.gutter'.render()"
M.width = width

---@param buffer integer
---@param model table? pane model carrying source_numbers and source_kinds
function M.attach(buffer, model)
  models[buffer] = model
end

---@param buffer integer
function M.detach(buffer)
  models[buffer] = nil
end

function M.render()
  local model = models[vim.api.nvim_get_current_buf()]
  if not model then
    return blank
  end
  local number = model.source_numbers[vim.v.lnum]
  if not number then
    return blank
  end
  local kind = model.source_kinds[vim.v.lnum]
  if kind == "add" then
    return ("%%#NgitDiffAddNumber#%5d + "):format(number)
  elseif kind == "delete" then
    return ("%%#NgitDiffDeleteNumber#%5d - "):format(number)
  end
  return ("%%#NgitLineNr#%5d │ "):format(number)
end

return M
