local M = {}

--- Presents a labelled choice list and runs the chosen item's action.
---
--- `vim.ui.select` is used rather than a window of ngit's own so whichever picker
--- the editor is configured with answers. "Cancel" is always the first entry, so a
--- stray `<CR>` on an unfamiliar menu can never be the destructive option, and the
--- items are matched by position rather than by label so two entries may read the
--- same without one shadowing the other.
---@param prompt string
---@param items { label: string, detail?: string, action: fun() }[]
function M.choose(prompt, items)
  local labels = { "Cancel" }
  for _, item in ipairs(items) do
    labels[#labels + 1] = item.detail and ("%s  ·  %s"):format(item.label, item.detail)
      or item.label
  end
  vim.ui.select(labels, { prompt = prompt }, function(_, index)
    if not index or index <= 1 then
      return
    end
    local item = items[index - 1]
    if item then
      item.action()
    end
  end)
end

--- Confirmation whose affirmative label spells out what is about to happen, so
--- the choice reads as the action rather than as "yes".
---@param prompt string
---@param label string
---@param perform fun()
function M.confirm(prompt, label, perform)
  vim.ui.select({ "Cancel", label }, { prompt = prompt }, function(choice)
    if choice == label then
      perform()
    end
  end)
end

--- Single-line input that skips the callback on cancel and on an empty answer, so
--- callers never have to distinguish the two.
---@param prompt string
---@param default string?
---@param perform fun(value: string)
function M.ask(prompt, default, perform)
  vim.ui.input({ prompt = prompt, default = default or "" }, function(value)
    if value == nil then
      return
    end
    value = vim.trim(value)
    if value == "" then
      return
    end
    perform(value)
  end)
end

return M
