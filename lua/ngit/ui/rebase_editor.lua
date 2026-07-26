local RebaseEditor = {}
RebaseEditor.__index = RebaseEditor

local next_id = 0
local namespace = vim.api.nvim_create_namespace("ngit_rebase")

--- The actions a step can carry, in the order the cycle key walks them.
local cycle = { "pick", "reword", "edit", "squash", "fixup", "drop" }

local action_groups = {
  pick = "NgitStaged",
  reword = "NgitBranchLocal",
  edit = "NgitUnstaged",
  squash = "NgitDecoration",
  fixup = "NgitDecoration",
  drop = "NgitConflict",
}

local action_help = {
  pick = "keep the commit as it is",
  reword = "stop afterwards so the message can be amended",
  edit = "stop with the commit applied",
  squash = "fold into the previous commit, keeping both messages",
  fixup = "fold into the previous commit, discarding this message",
  drop = "leave the commit out",
}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit rebase" })
end

local function short_oid(oid)
  return oid:sub(1, 8)
end

--- Plan the editor is showing, oldest commit first, which is the order git's todo
--- list uses and therefore the order the rows are read in.
---@param opts { base: string, label: string, steps: NgitRebaseStep[], on_submit: fun(steps: NgitRebaseStep[]), on_close: fun() }
function RebaseEditor.new(opts)
  next_id = next_id + 1
  local self = setmetatable({
    id = next_id,
    base = opts.base,
    label = opts.label,
    steps = vim.deepcopy(opts.steps),
    on_submit = opts.on_submit,
    on_close = opts.on_close,
    submitted = false,
    closed = false,
  }, RebaseEditor)
  self:open()
  return self
end

function RebaseEditor:title()
  return (" Rebase onto %s  —  <C-s> run, q abort "):format(self.label)
end

function RebaseEditor:render()
  local lines, spans = {}, {}
  for index, step in ipairs(self.steps) do
    local text = ("  %-6s %s  %s"):format(step.action, short_oid(step.oid), step.subject)
    lines[#lines + 1] = text
    spans[#spans + 1] = {
      row = index - 1,
      col = 2,
      end_col = 2 + #step.action,
      group = action_groups[step.action] or "NgitMuted",
    }
    spans[#spans + 1] = {
      row = index - 1,
      col = 9,
      end_col = 9 + 8,
      group = "NgitCommitHash",
    }
  end
  if #lines == 0 then
    lines = { "  Nothing to replay." }
  end

  vim.bo[self.buffer].modifiable = true
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, lines)
  vim.bo[self.buffer].modifiable = false
  vim.api.nvim_buf_clear_namespace(self.buffer, namespace, 0, -1)
  for _, span in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, self.buffer, namespace, span.row, span.col, {
      end_col = span.end_col,
      hl_group = span.group,
    })
  end
end

function RebaseEditor:row()
  if not vim.api.nvim_win_is_valid(self.window) then
    return 1
  end
  return math.min(vim.api.nvim_win_get_cursor(self.window)[1], math.max(1, #self.steps))
end

function RebaseEditor:set_action(action)
  local row = self:row()
  local step = self.steps[row]
  if not step then
    return
  end
  if (action == "squash" or action == "fixup") and row == 1 then
    notify("The first commit has nothing before it to fold into", vim.log.levels.WARN)
    return
  end
  step.action = action
  self:render()
  notify(("%s: %s"):format(action, action_help[action] or ""))
end

function RebaseEditor:cycle_action(delta)
  local step = self.steps[self:row()]
  if not step then
    return
  end
  local current = 1
  for index, action in ipairs(cycle) do
    if action == step.action then
      current = index
    end
  end
  local target = ((current - 1 + delta) % #cycle) + 1
  self:set_action(cycle[target])
end

--- Moving a row keeps the cursor on the commit it was on, so a run of moves reads
--- as dragging one commit rather than stepping through the list.
function RebaseEditor:move(delta)
  local row = self:row()
  local target = row + delta
  if target < 1 or target > #self.steps then
    return
  end
  self.steps[row], self.steps[target] = self.steps[target], self.steps[row]
  self:render()
  pcall(vim.api.nvim_win_set_cursor, self.window, { target, 0 })
end

function RebaseEditor:submit()
  if self.submitted or self.closed then
    return
  end
  local kept = 0
  for _, step in ipairs(self.steps) do
    if step.action ~= "drop" then
      kept = kept + 1
    end
  end
  if kept == 0 then
    notify("Dropping every commit is not something ngit will run", vim.log.levels.WARN)
    return
  end
  self.submitted = true
  local plan = self.steps
  self:close()
  self.on_submit(plan)
end

function RebaseEditor:focus()
  if vim.api.nvim_win_is_valid(self.window) then
    vim.api.nvim_set_current_win(self.window)
  end
end

function RebaseEditor:open()
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.buffer, ("ngit://rebase/%d"):format(self.id))
  vim.bo[self.buffer].buftype = "nofile"
  vim.bo[self.buffer].bufhidden = "wipe"
  vim.bo[self.buffer].swapfile = false
  vim.bo[self.buffer].filetype = "ngit-rebase"

  local width = math.min(math.max(56, math.floor(vim.o.columns * 0.6)), vim.o.columns - 4)
  local height = math.min(math.max(8, #self.steps + 2), vim.o.lines - 6)
  local window_config = {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = self:title(),
    title_pos = "center",
    footer = " p r e s f d set · J K move · <C-s> run ",
    footer_pos = "center",
  }
  -- The footer is where the key sheet lives, but it is newer than the oldest
  -- Neovim ngit supports, so a rejected option costs the hint rather than the
  -- window.
  local ok, window = pcall(vim.api.nvim_open_win, self.buffer, true, window_config)
  if not ok then
    window_config.footer = nil
    window_config.footer_pos = nil
    window = vim.api.nvim_open_win(self.buffer, true, window_config)
  end
  self.window = window
  vim.wo[self.window].wrap = false
  vim.wo[self.window].cursorline = true
  vim.wo[self.window].winhighlight = "FloatBorder:NgitMuted"
  self:render()

  local function map(key, callback, description)
    vim.keymap.set("n", key, callback, {
      buffer = self.buffer,
      nowait = true,
      silent = true,
      desc = "ngit rebase: " .. description,
    })
  end

  -- One key per action, taken from the verb's own initial except `edit`, which
  -- shares one with nothing and keeps `e`.
  for key, action in pairs({
    p = "pick",
    r = "reword",
    e = "edit",
    s = "squash",
    f = "fixup",
    d = "drop",
  }) do
    local selected = action
    map(key, function()
      self:set_action(selected)
    end, selected)
  end
  map("<Tab>", function()
    self:cycle_action(1)
  end, "next action")
  map("<S-Tab>", function()
    self:cycle_action(-1)
  end, "previous action")
  map("J", function()
    self:move(1)
  end, "move down")
  map("K", function()
    self:move(-1)
  end, "move up")
  map("<C-s>", function()
    self:submit()
  end, "run the rebase")
  for _, key in ipairs({ "q", "<Esc>" }) do
    map(key, function()
      self:close()
    end, "abort")
  end
end

function RebaseEditor:close()
  if self.closed then
    return
  end
  self.closed = true
  if vim.api.nvim_win_is_valid(self.window) then
    pcall(vim.api.nvim_win_close, self.window, true)
  end
  if self.on_close then
    self.on_close()
  end
end

RebaseEditor.actions = cycle

return RebaseEditor
