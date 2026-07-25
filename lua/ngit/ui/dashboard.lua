local Dashboard = {}
Dashboard.__index = Dashboard

local panel_order = { "status", "branches", "commits", "stashes" }
local panel_titles = {
  status = "Changes",
  branches = "Branches",
  commits = "Commits",
  stashes = "Stashes",
}

local function valid_buffer(buffer)
  return buffer and vim.api.nvim_buf_is_valid(buffer)
end

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function scratch_buffer(name, filetype)
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buffer, name)
  vim.bo[buffer].buftype = "nofile"
  vim.bo[buffer].bufhidden = "wipe"
  vim.bo[buffer].swapfile = false
  vim.bo[buffer].undofile = false
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].filetype = filetype
  return buffer
end

local function set_lines(buffer, lines)
  if not valid_buffer(buffer) then
    return
  end
  vim.bo[buffer].modifiable = true
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, #lines > 0 and lines or { "" })
  vim.bo[buffer].modifiable = false
  vim.bo[buffer].modified = false
end

local function escape_statusline(value)
  return (value or ""):gsub("%%", "%%%%"):gsub("[\r\n]", " ")
end

local function truncate(value, width)
  if width <= 0 or vim.fn.strdisplaywidth(value) <= width then
    return value
  end
  if width == 1 then
    return "…"
  end
  local result = ""
  local index = 0
  while index < vim.fn.strchars(value) do
    local next_value = result .. vim.fn.strcharpart(value, index, 1)
    if vim.fn.strdisplaywidth(next_value .. "…") > width then
      break
    end
    result = next_value
    index = index + 1
  end
  return result .. "…"
end

local function configure_panel(window)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].cursorline = true
  vim.wo[window].wrap = false
  vim.wo[window].winfixwidth = true
end

local function configure_ngit_window(window, config)
  if not valid_window(window) then
    return
  end
  if config.hide_statusline then
    vim.wo[window].statusline = "%#NgitStatusline# "
  end
end

local function configure_preview(window, config)
  vim.wo[window].number = false
  vim.wo[window].relativenumber = false
  vim.wo[window].signcolumn = "no"
  vim.wo[window].wrap = false
  vim.wo[window].scrollbind = true
  vim.wo[window].cursorbind = true
  configure_ngit_window(window, config)
end

---@param session_id integer
---@param config NgitConfig
function Dashboard.open(session_id, config)
  if vim.o.columns < 40 or vim.o.lines < 16 then
    error(
      ("ngit needs an editor area of at least 40 columns by 16 lines (current: %d by %d)"):format(
        vim.o.columns,
        vim.o.lines
      ),
      2
    )
  end
  local self = setmetatable({
    id = session_id,
    config = config,
    panels = {},
    active_panel = "status",
    disposed = false,
    namespace = vim.api.nvim_create_namespace(("ngit_dashboard_%d"):format(session_id)),
  }, Dashboard)

  vim.cmd("tabnew")
  self.tab = vim.api.nvim_get_current_tabpage()
  local main_window = vim.api.nvim_get_current_win()

  vim.cmd("botright 1split")
  self.actions = {
    window = vim.api.nvim_get_current_win(),
    buffer = scratch_buffer(("ngit://%d/actions"):format(session_id), "ngit"),
  }
  vim.api.nvim_win_set_buf(self.actions.window, self.actions.buffer)
  vim.wo[self.actions.window].number = false
  vim.wo[self.actions.window].relativenumber = false
  vim.wo[self.actions.window].signcolumn = "no"
  vim.wo[self.actions.window].cursorline = false
  vim.wo[self.actions.window].wrap = false
  vim.wo[self.actions.window].winfixheight = true
  configure_ngit_window(self.actions.window, config)
  pcall(vim.api.nvim_win_set_height, self.actions.window, 1)

  vim.api.nvim_set_current_win(main_window)
  vim.cmd("rightbelow vsplit")
  local preview_header_window = vim.api.nvim_get_current_win()
  local preview_header_buffer =
    scratch_buffer(("ngit://%d/preview-header"):format(session_id), "ngit")
  vim.api.nvim_win_set_buf(preview_header_window, preview_header_buffer)
  vim.wo[preview_header_window].number = false
  vim.wo[preview_header_window].relativenumber = false
  vim.wo[preview_header_window].signcolumn = "no"
  vim.wo[preview_header_window].wrap = false
  vim.wo[preview_header_window].winfixheight = true
  configure_ngit_window(preview_header_window, config)

  vim.cmd("belowright split")
  local preview_body_window = vim.api.nvim_get_current_win()
  local preview_left_buffer = scratch_buffer(("ngit://%d/diff-old"):format(session_id), "ngit-diff")
  vim.bo[preview_left_buffer].bufhidden = "hide"
  local preview_right_buffer =
    scratch_buffer(("ngit://%d/diff-new"):format(session_id), "ngit-diff")
  vim.bo[preview_right_buffer].bufhidden = "hide"
  local preview_unified_buffer =
    scratch_buffer(("ngit://%d/diff-unified"):format(session_id), "ngit-diff")
  vim.bo[preview_unified_buffer].bufhidden = "hide"

  local preview_width = vim.api.nvim_win_get_width(preview_header_window)
  local initial_layout = config.diff_layout
  if initial_layout == "auto" then
    initial_layout = preview_width >= config.side_by_side_min_width and "side_by_side" or "unified"
  elseif initial_layout == "side_by_side" and preview_width < 40 then
    initial_layout = "unified"
  end

  local preview_left_window
  local preview_right_window
  local preview_unified_window
  if initial_layout == "side_by_side" then
    preview_left_window = preview_body_window
    vim.api.nvim_win_set_buf(preview_left_window, preview_left_buffer)
    configure_preview(preview_left_window, config)
    vim.api.nvim_set_current_win(preview_left_window)
    vim.cmd("rightbelow vsplit")
    preview_right_window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(preview_right_window, preview_right_buffer)
    configure_preview(preview_right_window, config)
  else
    preview_unified_window = preview_body_window
    vim.api.nvim_win_set_buf(preview_unified_window, preview_unified_buffer)
    configure_preview(preview_unified_window, config)
  end

  local active_window = preview_right_window or preview_unified_window
  local active_buffer = preview_right_window and preview_right_buffer or preview_unified_buffer
  self.preview = {
    header = { window = preview_header_window, buffer = preview_header_buffer },
    left = { window = preview_left_window, buffer = preview_left_buffer },
    right = { window = preview_right_window, buffer = preview_right_buffer },
    unified = { window = preview_unified_window, buffer = preview_unified_buffer },
    layout = initial_layout,
    window = active_window,
    buffer = active_buffer,
  }

  local panel_windows = { main_window }
  local previous = main_window
  for _ = 2, #panel_order do
    vim.api.nvim_set_current_win(previous)
    vim.cmd("belowright split")
    previous = vim.api.nvim_get_current_win()
    panel_windows[#panel_windows + 1] = previous
  end

  for index, id in ipairs(panel_order) do
    local panel = {
      id = id,
      index = index,
      title = panel_titles[id],
      window = panel_windows[index],
      buffer = scratch_buffer(("ngit://%d/%s"):format(session_id, id), "ngit"),
      count = 0,
      selected = 0,
      empty = true,
      detail = "",
    }
    self.panels[id] = panel
    vim.api.nvim_win_set_buf(panel.window, panel.buffer)
    configure_panel(panel.window)
    configure_ngit_window(panel.window, config)
    set_lines(panel.buffer, { "", "  Loading…" })
  end

  -- Normalize the split tree so the action window is a root-level footer
  -- spanning both the panel column and preview column.
  vim.api.nvim_set_current_win(self.actions.window)
  vim.cmd("wincmd J")
  pcall(vim.api.nvim_win_set_height, self.actions.window, 1)

  self:resize_sidebar()
  self:render_preview({ "", "  Select an entry to preview it." }, "Preview")
  self:render_actions({}, "")
  self:refresh_winbars()
  self:reflow()
  pcall(vim.api.nvim_win_set_height, self.actions.window, 1)
  vim.api.nvim_set_current_win(self.panels.status.window)
  return self
end

function Dashboard:resize_sidebar()
  local status = self.panels.status
  if not status or not valid_window(status.window) then
    return
  end
  local columns = vim.o.columns
  local configured = self.config.file_panel_width
  local width = configured < 1 and math.floor(columns * configured) or math.floor(configured)
  width = math.max(28, math.min(width, math.max(28, columns - 40)))
  for _, id in ipairs(panel_order) do
    local panel = self.panels[id]
    if valid_window(panel.window) then
      pcall(vim.api.nvim_win_set_width, panel.window, width)
    end
  end
end

function Dashboard:refresh_winbars()
  for _, id in ipairs(panel_order) do
    local panel = self.panels[id]
    if valid_window(panel.window) then
      local group = id == self.active_panel and "NgitPanelActive" or "NgitMuted"
      local position = panel.count > 0 and ("%d/%d"):format(panel.selected, panel.count) or "0"
      local detail = panel.detail ~= "" and (" · " .. panel.detail) or ""
      vim.wo[panel.window].winbar = ("%%#%s# [%d] %s %%#NgitMuted#%s%s "):format(
        group,
        panel.index,
        panel.title,
        position,
        escape_statusline(detail)
      )
    end
  end
end

function Dashboard:render_panel(id, model)
  local panel = self.panels[id]
  if not panel or not valid_buffer(panel.buffer) then
    return
  end
  panel.count = model.count or 0
  panel.selected = model.selected or 0
  panel.empty = model.empty == true
  panel.detail = model.detail or ""
  set_lines(panel.buffer, model.lines or { "" })
  vim.api.nvim_buf_clear_namespace(panel.buffer, self.namespace, 0, -1)
  for _, item in ipairs(model.highlights or {}) do
    local opts = {
      hl_group = item.group,
      priority = item.priority or 100,
      hl_mode = item.hl_mode or "combine",
    }
    if item.line then
      opts.line_hl_group = item.group
      opts.hl_group = nil
    else
      opts.end_col = item.end_col or item.col or 0
      opts.hl_eol = item.hl_eol == true
    end
    vim.api.nvim_buf_set_extmark(panel.buffer, self.namespace, item.row, item.col or 0, opts)
  end
  if model.selected_row and valid_window(panel.window) then
    pcall(vim.api.nvim_win_set_cursor, panel.window, { model.selected_row, 0 })
  end
  self:refresh_winbars()
  self:reflow()
end

function Dashboard:render_preview(lines, title, opts)
  opts = opts or {}
  self.preview.models = nil
  self.preview.filetype = nil
  set_lines(self.preview.header.buffer, { title .. (opts.truncated and " · truncated" or "") })
  for _, target in ipairs({
    self.preview.left,
    self.preview.right,
    self.preview.unified,
  }) do
    set_lines(target.buffer, lines)
    vim.api.nvim_buf_clear_namespace(target.buffer, self.namespace, 0, -1)
    if vim.treesitter and vim.treesitter.stop then
      pcall(vim.treesitter.stop, target.buffer)
    end
    vim.bo[target.buffer].filetype = "ngit-diff"
  end
  if valid_window(self.preview.header.window) then
    pcall(vim.api.nvim_win_set_height, self.preview.header.window, 1)
  end
  for _, item in ipairs(self:preview_windows()) do
    if opts.reset_cursor ~= false and valid_window(item.window) then
      pcall(vim.api.nvim_win_set_cursor, item.window, { 1, 0 })
    end
  end
end

local function render_source(self, target, model, filetype)
  set_lines(target.buffer, model.lines or { "" })
  vim.api.nvim_buf_clear_namespace(target.buffer, self.namespace, 0, -1)
  vim.bo[target.buffer].filetype = filetype or "ngit-diff"
  if filetype and vim.treesitter and vim.treesitter.start then
    pcall(vim.treesitter.start, target.buffer, filetype)
  end
  for row, number in ipairs(model.source_numbers or {}) do
    if number then
      local kind = model.source_kinds and model.source_kinds[row]
      local marker = kind == "add" and "+" or (kind == "delete" and "-" or "│")
      local group = kind == "add" and "NgitDiffAddNumber"
        or (kind == "delete" and "NgitDiffDeleteNumber" or "LineNr")
      vim.api.nvim_buf_set_extmark(target.buffer, self.namespace, row - 1, 0, {
        virt_text = { { ("%5d %s "):format(number, marker), group } },
        virt_text_pos = "inline",
        priority = 250,
      })
    end
  end
  for _, item in ipairs(model.highlights or {}) do
    local opts = {
      hl_group = item.group,
      priority = item.priority or 50,
      hl_mode = "combine",
    }
    if item.line then
      opts.line_hl_group = item.group
      opts.hl_group = nil
    else
      opts.end_col = item.end_col
    end
    vim.api.nvim_buf_set_extmark(target.buffer, self.namespace, item.row, item.col or 0, opts)
  end
end

function Dashboard:preview_width()
  return valid_window(self.preview.header.window)
      and vim.api.nvim_win_get_width(self.preview.header.window)
    or vim.o.columns
end

function Dashboard:supports_side_by_side()
  return self:preview_width() >= 40
end

function Dashboard:desired_preview_layout()
  local width = self:preview_width()
  if self.config.diff_layout == "side_by_side" then
    return self:supports_side_by_side() and "side_by_side" or "unified"
  elseif self.config.diff_layout == "unified" then
    return "unified"
  end
  return width >= self.config.side_by_side_min_width and "side_by_side" or "unified"
end

function Dashboard:set_preview_layout(layout)
  if layout == "side_by_side" and not self:supports_side_by_side() then
    layout = "unified"
  end
  if layout == self.preview.layout then
    return layout
  end
  local origin = vim.api.nvim_get_current_win()
  if layout == "unified" then
    if valid_window(self.preview.left.window) then
      pcall(vim.api.nvim_win_hide, self.preview.left.window)
    end
    self.preview.left.window = nil
    self.preview.unified.window = self.preview.right.window
    vim.api.nvim_win_set_buf(self.preview.unified.window, self.preview.unified.buffer)
    configure_preview(self.preview.unified.window, self.config)
    self.preview.window = self.preview.unified.window
    self.preview.buffer = self.preview.unified.buffer
  else
    local body = self.preview.unified.window or self.preview.right.window
    self.preview.right.window = body
    vim.api.nvim_win_set_buf(body, self.preview.right.buffer)
    configure_preview(body, self.config)
    vim.api.nvim_set_current_win(body)
    vim.cmd("leftabove vsplit")
    self.preview.left.window = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.preview.left.window, self.preview.left.buffer)
    configure_preview(self.preview.left.window, self.config)
    self.preview.unified.window = nil
    self.preview.window = self.preview.right.window
    self.preview.buffer = self.preview.right.buffer
    vim.api.nvim_set_current_win(self.preview.right.window)
    vim.cmd("wincmd =")
  end
  self.preview.layout = layout
  if valid_window(origin) then
    vim.api.nvim_set_current_win(origin)
  end
  return layout
end

function Dashboard:render_diff(models, layout, filetype)
  layout = layout or self:desired_preview_layout()
  layout = self:set_preview_layout(layout)
  local active = layout == "side_by_side" and models.split or models.unified
  local header = active and active.header or { "Diff" }
  local width = valid_window(self.preview.header.window)
      and vim.api.nvim_win_get_width(self.preview.header.window)
    or vim.o.columns
  local header_lines = {}
  for _, line in ipairs(header) do
    header_lines[#header_lines + 1] = truncate(line, math.max(1, width - 1))
  end
  set_lines(self.preview.header.buffer, header_lines)
  if valid_window(self.preview.header.window) then
    pcall(vim.api.nvim_win_set_height, self.preview.header.window, math.max(1, #header_lines))
  end
  pcall(vim.api.nvim_win_set_height, self.actions.window, 1)
  if layout == "side_by_side" then
    render_source(self, self.preview.left, models.split.left, filetype)
    render_source(self, self.preview.right, models.split.right, filetype)
  else
    render_source(self, self.preview.unified, models.unified.unified, nil)
  end
  self.preview.models = models
  self.preview.filetype = filetype
  if layout == "side_by_side" then
    pcall(vim.api.nvim_win_set_cursor, self.preview.left.window, { 1, 0 })
    pcall(vim.api.nvim_win_set_cursor, self.preview.right.window, { 1, 0 })
  else
    pcall(vim.api.nvim_win_set_cursor, self.preview.unified.window, { 1, 0 })
  end
  return layout
end

function Dashboard:preview_windows()
  local result = {}
  for _, item in ipairs({
    self.preview.header,
    self.preview.left,
    self.preview.right,
    self.preview.unified,
  }) do
    if item and valid_window(item.window) then
      result[#result + 1] = item
    end
  end
  return result
end

function Dashboard:focus_preview(side)
  local target
  if self.preview.layout == "unified" then
    target = self.preview.unified
  else
    target = side == "left" and self.preview.left or self.preview.right
  end
  if target and valid_window(target.window) then
    vim.api.nvim_set_current_win(target.window)
    self.preview.window = target.window
    self.preview.buffer = target.buffer
    return true
  end
  return false
end

function Dashboard:reassert_statusline(window)
  if self.config.hide_statusline and valid_window(window) then
    vim.wo[window].statusline = "%#NgitStatusline# "
  end
end

function Dashboard:render_actions(items, detail, detail_group)
  if not valid_buffer(self.actions.buffer) then
    return
  end
  local parts = {}
  for _, item in ipairs(items or {}) do
    parts[#parts + 1] = ("%s:%s"):format(item.key, item.label)
  end
  local left = table.concat(parts, "  ")
  local width = valid_window(self.actions.window)
      and vim.api.nvim_win_get_width(self.actions.window)
    or vim.o.columns
  local suffix = detail and detail ~= "" and ("  ·  " .. detail) or ""
  local line = truncate(left .. suffix, math.max(1, width - 1))
  set_lines(self.actions.buffer, { line })
  vim.api.nvim_buf_clear_namespace(self.actions.buffer, self.namespace, 0, -1)
  if detail and detail ~= "" and detail_group then
    local start = line:find("·", 1, true)
    if start then
      vim.api.nvim_buf_set_extmark(self.actions.buffer, self.namespace, 0, start - 1, {
        end_col = #line,
        hl_group = detail_group,
      })
    end
  end
end

function Dashboard:focus_panel(id)
  local panel = self.panels[id]
  if not panel or not valid_window(panel.window) then
    return false
  end
  self.active_panel = id
  self:refresh_winbars()
  self:reflow()
  vim.api.nvim_set_current_win(panel.window)
  return true
end

function Dashboard:reflow()
  if self.disposed then
    return
  end
  local total = 0
  for _, id in ipairs(panel_order) do
    local panel = self.panels[id]
    if not valid_window(panel.window) then
      return
    end
    total = total + vim.api.nvim_win_get_height(panel.window)
  end
  if total < #panel_order then
    return
  end

  local heights = {}
  local remaining = total
  local weighted = {}
  for _, id in ipairs(panel_order) do
    local panel = self.panels[id]
    local minimum = panel.empty and id ~= self.active_panel and 1
      or (id == self.active_panel and 3 or 2)
    heights[id] = minimum
    remaining = remaining - minimum
    weighted[#weighted + 1] = id
  end
  local weights = { status = 2, branches = 1, commits = 2, stashes = 1 }
  while remaining > 0 do
    local progressed = false
    for _, id in ipairs(weighted) do
      for _ = 1, weights[id] do
        if remaining <= 0 then
          break
        end
        heights[id] = heights[id] + 1
        remaining = remaining - 1
        progressed = true
      end
    end
    if not progressed then
      break
    end
  end

  for index = 1, #panel_order - 1 do
    local panel = self.panels[panel_order[index]]
    pcall(vim.api.nvim_win_set_height, panel.window, heights[panel.id])
  end
end

function Dashboard:resize()
  if self.disposed then
    return
  end
  self:resize_sidebar()
  if valid_window(self.actions.window) then
    pcall(vim.api.nvim_win_set_height, self.actions.window, 1)
  end
  self:reflow()
end

function Dashboard:all_buffers()
  local buffers = {
    self.preview.header.buffer,
    self.preview.left.buffer,
    self.preview.right.buffer,
    self.preview.unified.buffer,
    self.actions.buffer,
  }
  for _, id in ipairs(panel_order) do
    buffers[#buffers + 1] = self.panels[id].buffer
  end
  return buffers
end

function Dashboard:dispose()
  if self.disposed then
    return
  end
  self.disposed = true
  for _, buffer in ipairs(self:all_buffers()) do
    if valid_buffer(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
end

Dashboard.panel_order = panel_order
Dashboard.valid_buffer = valid_buffer
Dashboard.valid_window = valid_window

return Dashboard
