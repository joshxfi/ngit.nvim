local actions = require("ngit.ui.actions")

local M = {}

--- Presentation order for the key sheet. Actions that are not listed here are
--- appended under "Other" so a newly registered action can never go missing.
local groups = {
  {
    title = "Panels",
    items = {
      { "focus_status", "Changes" },
      { "focus_branches", "Branches" },
      { "focus_commits", "Commits" },
      { "focus_stashes", "Stashes" },
      { "next_panel", "Next panel" },
      { "prev_panel", "Previous panel" },
      { "filter", "Filter panel" },
    },
  },
  {
    title = "Movement",
    items = {
      { "next_item", "Next item" },
      { "prev_item", "Previous item" },
      { "select", "Focus preview" },
      { "focus_preview", "Focus preview" },
      { "focus_files", "Back to panel" },
      { "next_hunk", "Next hunk" },
      { "prev_hunk", "Previous hunk" },
      { "next_diff_file", "Next changed file" },
      { "prev_diff_file", "Previous changed file" },
      { "next_conflict", "Next conflict block" },
      { "prev_conflict", "Previous conflict block" },
      { "toggle_diff", "Split / unified diff" },
      { "toggle_whitespace", "Ignore whitespace changes" },
      { "increase_context", "More context lines" },
      { "decrease_context", "Fewer context lines" },
    },
  },
  {
    title = "Changes",
    items = {
      { "stage", "Stage file, hunk, or selection" },
      { "unstage", "Unstage file, hunk, or selection" },
      { "stage_all", "Stage everything" },
      { "unstage_all", "Unstage everything" },
      { "discard", "Discard file, hunk, or selection" },
      { "open_file", "Open at the reviewed line" },
      { "commit", "Commit" },
      { "amend", "Amend last commit" },
      { "commit_menu", "Commit options" },
      { "file_menu", "Untrack, rename, restore" },
      { "stash_menu", "Stash options" },
    },
  },
  {
    title = "Branches, tags, and history",
    items = {
      { "primary_action", "Check out / copy SHA" },
      { "new_item", "New branch or stash" },
      { "delete_item", "Delete or drop" },
      { "rename_item", "Rename branch" },
      { "set_upstream", "Set or clear the upstream" },
      { "tag", "Create a tag" },
      { "merge", "Merge branch" },
      { "rebase", "Rebase onto branch" },
      { "interactive_rebase", "Interactive rebase plan" },
      { "cherry_pick", "Cherry-pick commit" },
      { "revert", "Revert commit" },
      { "reset", "Reset onto the selection" },
      { "checkout_commit", "Check out with a detached HEAD" },
      { "load_more", "Load more commits" },
      { "apply_item", "Apply stash" },
      { "pop_item", "Pop stash" },
    },
  },
  {
    title = "Review",
    items = {
      { "review", "Review a revision range" },
      { "file_history", "Follow one file's history" },
      { "blame", "Blame the selected file" },
      { "copy_menu", "Copy hash, path, or patch" },
      { "repos_menu", "Worktrees and submodules" },
    },
  },
  {
    title = "Conflicts and remotes",
    items = {
      { "choose_ours", "Take ours" },
      { "choose_theirs", "Take theirs" },
      { "choose_both", "Take both" },
      { "continue_operation", "Continue operation" },
      { "abort_operation", "Abort operation" },
      { "fetch", "Fetch" },
      { "pull", "Pull (fast-forward)" },
      { "push", "Push" },
      { "remote_menu", "Remote options" },
    },
  },
  {
    title = "Session",
    items = {
      { "refresh", "Refresh" },
      { "help", "This help" },
      { "close", "Close ngit" },
    },
  },
}

local function grouped(mappings)
  local listed = {}
  local result = {}
  for _, group in ipairs(groups) do
    local items = {}
    for _, item in ipairs(group.items) do
      local key = mappings[item[1]]
      if key and key ~= false and key ~= "" then
        listed[item[1]] = true
        items[#items + 1] = { key = key, label = item[2] }
      end
    end
    if #items > 0 then
      result[#result + 1] = { title = group.title, items = items }
    end
  end

  local extra = {}
  for _, action in ipairs(actions.definitions()) do
    local key = mappings[action.mapping]
    if not listed[action.mapping] and key and key ~= false and key ~= "" then
      listed[action.mapping] = true
      extra[#extra + 1] = { key = key, label = action.label }
    end
  end
  if #extra > 0 then
    result[#result + 1] = { title = "Other", items = extra }
  end
  return result
end

local function key_width(sections)
  local width = vim.fn.strdisplaywidth("<Esc>")
  for _, section in ipairs(sections) do
    for _, item in ipairs(section.items) do
      width = math.max(width, vim.fn.strdisplaywidth(item.key))
    end
  end
  return width
end

--- Plain-text rendering, kept as the fallback for callers without a window.
---@param mappings table
---@return string[]
function M.lines(mappings)
  local sections = grouped(mappings)
  local width = key_width(sections)
  local lines = { "ngit mappings" }
  for _, section in ipairs(sections) do
    lines[#lines + 1] = ""
    lines[#lines + 1] = section.title
    for _, item in ipairs(section.items) do
      lines[#lines + 1] = ("  %s%s  %s"):format(
        item.key,
        string.rep(" ", width - vim.fn.strdisplaywidth(item.key)),
        item.label
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ("  %-" .. width .. "s  %s"):format("<Esc>", "Return to active panel")
  return lines
end

--- Builds the float's buffer content together with the spans that colour it.
local function render(mappings)
  local sections = grouped(mappings)
  local width = key_width(sections)
  local lines, highlights = {}, {}
  local text_width = 0

  local function push(text, spans)
    lines[#lines + 1] = text
    text_width = math.max(text_width, vim.fn.strdisplaywidth(text))
    for _, span in ipairs(spans or {}) do
      span.row = #lines - 1
      highlights[#highlights + 1] = span
    end
  end

  for index, section in ipairs(sections) do
    if index > 1 then
      push("")
    end
    push("  " .. section.title, { { col = 2, end_col = 2 + #section.title, group = "NgitHeader" } })
    for _, item in ipairs(section.items) do
      local padding = string.rep(" ", width - vim.fn.strdisplaywidth(item.key))
      local text = ("   %s%s   %s"):format(item.key, padding, item.label)
      push(text, {
        { col = 3, end_col = 3 + #item.key, group = "NgitActionKey" },
        { col = #text - #item.label, end_col = #text, group = "NgitActionLabel" },
      })
    end
  end
  return lines, highlights, text_width
end

--- Opens the key sheet as a float. Returns the window so a caller can close it.
---@param mappings table
---@return integer? window
function M.open(mappings)
  local lines, highlights, text_width = render(mappings)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "ngit-help"

  local namespace = vim.api.nvim_create_namespace("ngit_help")
  for _, span in ipairs(highlights) do
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, span.row, span.col, {
      end_col = span.end_col,
      hl_group = span.group,
    })
  end

  local width = math.max(30, math.min(text_width + 4, vim.o.columns - 8))
  local height = math.max(8, math.min(#lines, vim.o.lines - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " ngit · keys ",
    title_pos = "center",
  })
  vim.wo[window].wrap = false
  vim.wo[window].cursorline = true
  vim.wo[window].winhighlight = "FloatBorder:NgitMuted"

  local function close()
    if vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_close(window, true)
    end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close, {
      buffer = buffer,
      nowait = true,
      silent = true,
      desc = "ngit: close help",
    })
  end
  return window
end

return M
