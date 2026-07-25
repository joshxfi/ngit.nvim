local actions = require("ngit.ui.actions")

local M = {}

local navigation = {
  { "focus_status", "Focus changes" },
  { "focus_branches", "Focus branches" },
  { "focus_commits", "Focus commits" },
  { "focus_stashes", "Focus stashes" },
  { "next_panel", "Next panel" },
  { "prev_panel", "Previous panel" },
  { "next_item", "Next item" },
  { "prev_item", "Previous item" },
  { "select", "Focus preview" },
  { "focus_files", "Return to active panel" },
  { "focus_preview", "Focus preview" },
  { "next_hunk", "Next hunk" },
  { "prev_hunk", "Previous hunk" },
  { "next_diff_file", "Next changed file" },
  { "prev_diff_file", "Previous changed file" },
  { "toggle_diff", "Toggle split/unified diff" },
}

function M.lines(mappings)
  local items = {}
  local seen = {}
  local function add(mapping, label)
    local key = mappings[mapping]
    if key and key ~= false and key ~= "" then
      local identity = key .. "\0" .. label
      if not seen[identity] then
        seen[identity] = true
        items[#items + 1] = { key = key, label = label }
      end
    end
  end
  for _, item in ipairs(navigation) do
    add(item[1], item[2])
  end
  for _, item in ipairs(actions.help_items(mappings)) do
    local identity = item.key .. "\0" .. item.label
    if not seen[identity] then
      seen[identity] = true
      items[#items + 1] = item
    end
  end

  local width = vim.fn.strdisplaywidth("<Esc>")
  for _, item in ipairs(items) do
    width = math.max(width, vim.fn.strdisplaywidth(item.key))
  end
  local lines = { "ngit mappings", "" }
  for _, item in ipairs(items) do
    lines[#lines + 1] = ("%s%s  %s"):format(
      item.key,
      string.rep(" ", width - vim.fn.strdisplaywidth(item.key)),
      item.label
    )
  end
  lines[#lines + 1] = ("%-" .. width .. "s  %s"):format("<Esc>", "Return to active panel")
  return lines
end

return M
