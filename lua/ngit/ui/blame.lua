local Render = require("ngit.ui.render")
local blame_backend = require("ngit.git.blame")

local M = {}

local namespace = vim.api.nvim_create_namespace("ngit_blame")

--- Widths of the annotation columns. Fixed rather than measured so every row
--- starts its source text at the same offset: an author column that grew to fit
--- the longest name would make the code unreadable in a file with one long one.
local oid_width = 8
local author_width = 14
local age_width = 4

local function truncate(value, width)
  if vim.fn.strdisplaywidth(value) <= width then
    return value .. string.rep(" ", width - vim.fn.strdisplaywidth(value))
  end
  local result = ""
  local index = 0
  while index < vim.fn.strchars(value) do
    local candidate = result .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(candidate) > width - 1 then
      break
    end
    result = candidate
    index = index + 1
  end
  return result .. "…" .. string.rep(" ", math.max(0, width - vim.fn.strdisplaywidth(result) - 1))
end

--- Builds the annotated buffer and the spans that colour it.
---
--- A run of lines from the same commit shows its annotation only on the first
--- row. Repeating it would turn the column into noise, and the gap is what makes
--- a commit's extent visible at a glance.
---@param lines NgitBlameLine[]
---@param commits table<string, NgitBlameCommit>
---@return string[], table[], table<integer, string>
local function render(lines, commits)
  local text, spans, oid_at_row = {}, {}, {}
  local previous
  local blank = string.rep(" ", oid_width + author_width + age_width + 3)
  for _, line in ipairs(lines) do
    local commit = commits[line.oid] or { author = "", timestamp = 0 }
    local annotation
    if line.oid == previous then
      annotation = blank
    elseif line.oid == blame_backend.uncommitted then
      annotation = ("%s %s %s"):format(
        truncate("––––––––", oid_width),
        truncate("not committed", author_width),
        truncate("now", age_width)
      )
    else
      annotation = ("%s %s %s"):format(
        truncate(line.oid:sub(1, oid_width), oid_width),
        truncate(commit.author, author_width),
        truncate(Render.age(commit.timestamp), age_width)
      )
    end
    previous = line.oid

    local row = #text
    text[#text + 1] = ("%s │ %s"):format(annotation, line.text)
    oid_at_row[row + 1] = line.oid
    if annotation ~= blank then
      spans[#spans + 1] = { row = row, col = 0, end_col = oid_width, group = "NgitCommitHash" }
      spans[#spans + 1] = {
        row = row,
        col = oid_width + 1,
        end_col = oid_width + 1 + author_width,
        group = "NgitMuted",
      }
      spans[#spans + 1] = {
        row = row,
        col = oid_width + author_width + 2,
        end_col = oid_width + author_width + 2 + age_width,
        group = "NgitDate",
      }
    end
    spans[#spans + 1] = {
      row = row,
      col = #blank,
      end_col = #blank + #" │",
      group = "NgitPathDim",
    }
  end
  return text, spans, oid_at_row
end

--- Opens the annotated file as a float.
---@param opts { path: string, lines: NgitBlameLine[], commits: table, cursor?: integer, on_commit?: fun(oid: string) }
---@return table
function M.open(opts)
  local text, spans, oid_at_row = render(opts.lines, opts.commits)
  if #text == 0 then
    text = { "  Nothing to blame." }
  end

  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, ("ngit://blame/%s"):format(opts.path))
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, text)
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].filetype = "ngit-blame"
  for _, span in ipairs(spans) do
    pcall(vim.api.nvim_buf_set_extmark, buffer, namespace, span.row, span.col, {
      end_col = span.end_col,
      hl_group = span.group,
    })
  end

  local width = math.max(60, math.min(vim.o.columns - 8, 140))
  local height = math.max(10, math.min(#text + 1, vim.o.lines - 8))
  local window = vim.api.nvim_open_win(buffer, true, {
    relative = "editor",
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = (" blame · %s "):format(opts.path),
    title_pos = "center",
  })
  vim.wo[window].wrap = false
  vim.wo[window].cursorline = true
  vim.wo[window].winhighlight = "FloatBorder:NgitMuted"
  if opts.cursor then
    pcall(vim.api.nvim_win_set_cursor, window, { math.min(opts.cursor, #text), 0 })
    vim.cmd("normal! zz")
  end

  local view = { window = window, buffer = buffer, closed = false }
  function view:close()
    if self.closed then
      return
    end
    self.closed = true
    if vim.api.nvim_win_is_valid(self.window) then
      pcall(vim.api.nvim_win_close, self.window, true)
    end
  end

  for _, key in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", key, function()
      view:close()
    end, { buffer = buffer, nowait = true, silent = true, desc = "ngit: close blame" })
  end
  vim.keymap.set("n", "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(window)[1]
    local oid = oid_at_row[row]
    if not oid or oid == blame_backend.uncommitted then
      return
    end
    view:close()
    if opts.on_commit then
      opts.on_commit(oid)
    end
  end, { buffer = buffer, nowait = true, silent = true, desc = "ngit: show this commit" })

  return view
end

return M
