local mutate = require("ngit.git.mutate")

local CommitEditor = {}
CommitEditor.__index = CommitEditor

local next_id = 0

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit commit" })
end

local function trim_message(lines)
  local first = 1
  local last = #lines
  while first <= last and lines[first]:match("^%s*$") do
    first = first + 1
  end
  while last >= first and lines[last]:match("^%s*$") do
    last = last - 1
  end
  local selected = {}
  for index = first, last do
    selected[#selected + 1] = lines[index]
  end
  return table.concat(selected, "\n")
end

---@param root string
---@param opts { amend: boolean, message?: string, staged?: integer, branch?: string, commit_options?: NgitCommitOptions, on_complete: fun() }
function CommitEditor.new(root, opts)
  next_id = next_id + 1
  local self = setmetatable({
    root = root,
    amend = opts.amend,
    staged = opts.staged,
    branch = opts.branch,
    -- Switches chosen from the commit menu travel with the editor, so the buffer
    -- the message is typed into records what the commit will actually run with.
    commit_options = opts.commit_options or { amend = opts.amend == true },
    on_complete = opts.on_complete,
    submitting = false,
    closed = false,
  }, CommitEditor)
  self:open(opts.message or "")
  return self
end

--- Names what is about to be recorded, so the editor is not a bare text box. The
--- chosen switches are part of that: signing off or skipping hooks changes what
--- the commit means, and the title is the last place to notice it.
function CommitEditor:title()
  local parts = { self.amend and "Amend" or "Commit" }
  if self.branch and self.branch ~= "" then
    parts[#parts + 1] = "on " .. self.branch
  end
  if self.staged and self.staged > 0 then
    parts[#parts + 1] = ("· %d file%s"):format(self.staged, self.staged == 1 and "" or "s")
  end
  local switches = {}
  for name, flag in pairs({
    signoff = "--signoff",
    no_verify = "--no-verify",
    gpg_sign = "--gpg-sign",
    allow_empty = "--allow-empty",
  }) do
    if self.commit_options[name] then
      switches[#switches + 1] = flag
    end
  end
  table.sort(switches)
  if #switches > 0 then
    parts[#parts + 1] = "· " .. table.concat(switches, " ")
  end
  return (" %s  —  <C-s> submit, q abort "):format(table.concat(parts, " "))
end

function CommitEditor:open(message)
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(self.buffer, ("ngit://commit/%d"):format(next_id))
  vim.bo[self.buffer].buftype = "acwrite"
  vim.bo[self.buffer].bufhidden = "wipe"
  vim.bo[self.buffer].swapfile = false
  vim.bo[self.buffer].filetype = "gitcommit"

  local lines = vim.split(message, "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, lines)
  vim.bo[self.buffer].modified = false

  local width = math.min(math.max(48, math.floor(vim.o.columns * 0.46)), vim.o.columns - 4)
  local height = math.min(math.max(10, math.floor(vim.o.lines * 0.35)), vim.o.lines - 4)
  self.window = vim.api.nvim_open_win(self.buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 2),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = self:title(),
    title_pos = "center",
  })
  vim.wo[self.window].wrap = true
  vim.wo[self.window].linebreak = true
  vim.wo[self.window].number = false
  vim.wo[self.window].signcolumn = "no"
  vim.wo[self.window].winhighlight = "FloatBorder:NgitMuted"
  -- The conventional 50/72 guides make the subject/body split visible.
  vim.wo[self.window].colorcolumn = "50,72"

  self.augroup = vim.api.nvim_create_augroup(("ngit_commit_%d"):format(next_id), { clear = true })
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = self.augroup,
    buffer = self.buffer,
    callback = function()
      self:submit()
    end,
  })

  local function submit()
    if vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
      vim.cmd.stopinsert()
    end
    self:submit()
  end
  vim.keymap.set("n", "<C-s>", submit, {
    buffer = self.buffer,
    silent = true,
    desc = "ngit: submit commit",
  })
  vim.keymap.set("i", "<C-s>", submit, {
    buffer = self.buffer,
    silent = true,
    desc = "ngit: submit commit",
  })
  vim.keymap.set("n", "q", function()
    self:request_close()
  end, {
    buffer = self.buffer,
    silent = true,
    nowait = true,
    desc = "ngit: abort commit",
  })

  vim.schedule(function()
    if valid_window(self.window) then
      vim.api.nvim_set_current_win(self.window)
      vim.cmd.startinsert()
    end
  end)
end

function CommitEditor:submit()
  if self.closed or self.submitting or not valid_buffer(self.buffer) then
    return
  end
  local message = trim_message(vim.api.nvim_buf_get_lines(self.buffer, 0, -1, false))
  if message == "" and not self.amend then
    notify("Commit message cannot be empty", vim.log.levels.WARN)
    return
  end
  self.submitting = true
  mutate.commit(self.root, message, self.commit_options, function(ok, err)
    self.submitting = false
    if not ok then
      notify(err or "Commit failed", vim.log.levels.ERROR)
      return
    end
    if valid_buffer(self.buffer) then
      vim.bo[self.buffer].modified = false
    end
    self:close()
    self.on_complete()
  end)
end

function CommitEditor:request_close()
  if not valid_buffer(self.buffer) or not vim.bo[self.buffer].modified then
    self:close()
    return
  end
  vim.ui.select({ "Keep editing", "Discard message" }, {
    prompt = "Discard the commit message?",
  }, function(choice)
    if choice == "Discard message" then
      self:close()
    end
  end)
end

function CommitEditor:close()
  if self.closed then
    return
  end
  self.closed = true
  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  end
  if valid_window(self.window) then
    vim.api.nvim_win_close(self.window, true)
  elseif valid_buffer(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
end

return CommitEditor
