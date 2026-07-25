local Console = {}
Console.__index = Console

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

function Console.new(title)
  local self = setmetatable({
    title = title,
    running = true,
    process = nil,
    lines = {},
    pending_lines = {},
    flush_scheduled = false,
    rendered_once = false,
    reset_on_flush = false,
    max_lines = 5000,
  }, Console)
  self:open()
  return self
end

function Console:open()
  self.buffer = vim.api.nvim_create_buf(false, true)
  vim.bo[self.buffer].buftype = "nofile"
  vim.bo[self.buffer].bufhidden = "wipe"
  vim.bo[self.buffer].swapfile = false
  vim.bo[self.buffer].filetype = "ngit-console"
  vim.bo[self.buffer].modifiable = false

  local width = math.max(40, math.floor(vim.o.columns * 0.8))
  local height = math.max(8, math.floor(vim.o.lines * 0.6))
  self.window = vim.api.nvim_open_win(self.buffer, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = math.min(width, vim.o.columns - 2),
    height = math.min(height, vim.o.lines - 4),
    style = "minimal",
    border = "rounded",
    title = " ngit · " .. self.title .. " ",
    title_pos = "center",
  })
  vim.wo[self.window].wrap = false
  vim.wo[self.window].cursorline = false

  vim.keymap.set("n", "q", function()
    self:close()
  end, { buffer = self.buffer, nowait = true, silent = true, desc = "ngit: close console" })
  vim.keymap.set("n", "<Esc>", function()
    self:close()
  end, { buffer = self.buffer, nowait = true, silent = true, desc = "ngit: close console" })
  self:append("$ " .. self.title)
end

function Console:append(data)
  if not valid_buffer(self.buffer) then
    return
  end
  local incoming = vim.split(data, "\n", { plain = true })
  if incoming[#incoming] == "" then
    table.remove(incoming)
  end
  for _, line in ipairs(incoming) do
    local clean = line:gsub("\r$", "")
    self.lines[#self.lines + 1] = clean
    self.pending_lines[#self.pending_lines + 1] = clean
  end
  local overflow = #self.lines - self.max_lines
  if overflow > 0 then
    local retained = {}
    for index = overflow + 1, #self.lines do
      retained[#retained + 1] = self.lines[index]
    end
    self.lines = retained
    self.reset_on_flush = true
  end
  if self.flush_scheduled then
    return
  end
  self.flush_scheduled = true
  vim.schedule(function()
    self:flush()
  end)
end

function Console:flush()
  self.flush_scheduled = false
  if not valid_buffer(self.buffer) then
    self.pending_lines = {}
    return
  end
  if #self.pending_lines == 0 and not self.reset_on_flush then
    return
  end
  vim.bo[self.buffer].modifiable = true
  if self.reset_on_flush or not self.rendered_once then
    vim.api.nvim_buf_set_lines(self.buffer, 0, -1, false, self.lines)
    self.rendered_once = true
  else
    vim.api.nvim_buf_set_lines(self.buffer, -1, -1, false, self.pending_lines)
  end
  vim.bo[self.buffer].modifiable = false
  self.pending_lines = {}
  self.reset_on_flush = false
  if valid_window(self.window) then
    pcall(vim.api.nvim_win_set_cursor, self.window, { math.max(1, #self.lines), 0 })
  end
end

function Console:finish(ok, code)
  self.running = false
  self.process = nil
  self:append("")
  self:append(ok and "Completed successfully." or ("Failed with exit code %d."):format(code))
  self:flush()
end

function Console:close()
  if self.process and self.running then
    pcall(self.process.kill, self.process, 15)
  end
  self.running = false
  self.process = nil
  if valid_window(self.window) then
    vim.api.nvim_win_close(self.window, true)
  elseif valid_buffer(self.buffer) then
    vim.api.nvim_buf_delete(self.buffer, { force = true })
  end
end

return Console
