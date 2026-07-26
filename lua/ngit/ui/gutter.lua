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
local panes = {}

local minimum_digits = 2
local maximum_digits = 6

M.expression = "%!v:lua.require'ngit.ui.gutter'.render()"

--- The column is only ever as wide as the largest number it has to show. A
--- fixed width would indent a commit preamble and every file header by room
--- reserved for line numbers that stretch of the patch does not have.
---@return integer digits, 0 when the pane carries no source numbers at all
local function digits_for(model)
  local highest = 0
  for _, number in pairs(model.source_numbers or {}) do
    if number and number > highest then
      highest = number
    end
  end
  if highest == 0 then
    return 0
  end
  return math.max(minimum_digits, math.min(maximum_digits, #tostring(highest)))
end

--- Digit count a pane needs on its own. Side-by-side panes are scroll-bound
--- row for row, so the caller takes the larger of the two and passes it to
--- both; otherwise an all-addition file, whose old side carries no numbers at
--- all, would shift one pane against the other.
---@param model table
---@return integer
function M.digits(model)
  return digits_for(model)
end

---@param buffer integer
---@param model table? pane model carrying source_numbers and source_kinds
---@param shared_digits integer? width to match a paired pane
function M.attach(buffer, model, shared_digits)
  local digits = model and math.max(digits_for(model), shared_digits or 0) or 0
  if digits == 0 then
    panes[buffer] = nil
    return
  end
  panes[buffer] = {
    model = model,
    -- "%#Group#" carries no display width, so a row is the number plus the one
    -- space separating it from the text.
    format = "%%#%s#%" .. digits .. "d ",
    blank = string.rep(" ", digits + 1),
  }
end

---@param buffer integer
function M.detach(buffer)
  panes[buffer] = nil
end

--- Width the column occupies for a buffer, or 0 when it is not drawn.
---@param buffer integer
---@return integer
function M.width(buffer)
  local pane = panes[buffer]
  return pane and #pane.blank or 0
end

function M.render()
  -- Set by Neovim to the window being drawn. The drawn window is usually not
  -- the current one, so resolving the buffer through it is the only reliable
  -- way to find the right pane.
  local window = vim.g.statusline_winid
  local buffer
  if window and window ~= 0 and vim.api.nvim_win_is_valid(window) then
    buffer = vim.api.nvim_win_get_buf(window)
  else
    buffer = vim.api.nvim_get_current_buf()
  end

  local pane = panes[buffer]
  if not pane then
    return ""
  end
  local number = pane.model.source_numbers[vim.v.lnum]
  if not number then
    return pane.blank
  end
  -- No +/- marker: the number cell carries the row's own accent and sits
  -- against the tinted line, which already says which side it belongs to.
  local kind = pane.model.source_kinds[vim.v.lnum]
  if kind == "add" then
    return pane.format:format("NgitDiffAddNumber", number)
  elseif kind == "delete" then
    return pane.format:format("NgitDiffDeleteNumber", number)
  end
  return pane.format:format("NgitLineNr", number)
end

return M
