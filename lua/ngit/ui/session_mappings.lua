local actions = require("ngit.ui.actions")
local Dashboard = require("ngit.ui.dashboard")

local M = {}

function M.install(self)
  local mappings = self.config.mappings
  local panel_buffers = {}
  local all_buffers = self.dashboard:all_buffers()
  for _, id in ipairs(Dashboard.panel_order) do
    panel_buffers[id] = self.dashboard.panels[id].buffer
  end

  local function map(key, callback, description, buffers)
    if not key or key == false or key == "" then
      return
    end
    for _, buffer in ipairs(buffers or all_buffers) do
      vim.keymap.set("n", key, callback, {
        buffer = buffer,
        silent = true,
        nowait = true,
        desc = "ngit: " .. description,
      })
    end
  end

  for _, id in ipairs(Dashboard.panel_order) do
    local selected_id = id
    map(mappings.next_item, function()
      self:focus_panel(selected_id)
      self:select_relative(1)
    end, "next item", { panel_buffers[id] })
    map(mappings.prev_item, function()
      self:focus_panel(selected_id)
      self:select_relative(-1)
    end, "previous item", { panel_buffers[id] })
    map(mappings.select, function()
      self:focus_panel(selected_id)
      self.dashboard:focus_preview()
    end, "focus selected preview", { panel_buffers[id] })
  end

  local panel_focus = {
    { mappings.status_view, "status" },
    { mappings.commit_view, "commits" },
    { mappings.branch_view, "branches" },
    { mappings.stash_view, "stashes" },
    { mappings.focus_status, "status" },
    { mappings.focus_branches, "branches" },
    { mappings.focus_commits, "commits" },
    { mappings.focus_stashes, "stashes" },
  }
  for _, item in ipairs(panel_focus) do
    local key, panel = item[1], item[2]
    map(key, function()
      self:focus_panel(panel)
    end, panel .. " panel")
  end

  map(mappings.next_panel, function()
    self:focus_relative_panel(1)
  end, "next panel")
  map(mappings.prev_panel, function()
    self:focus_relative_panel(-1)
  end, "previous panel")
  map(mappings.next_file, function()
    self:select_relative(1)
  end, "next item")
  map(mappings.prev_file, function()
    self:select_relative(-1)
  end, "previous item")

  local preview_buffers = {
    self.dashboard.preview.left.buffer,
    self.dashboard.preview.right.buffer,
    self.dashboard.preview.unified.buffer,
  }
  local preview_actions = {
    { mappings.next_hunk, "jump_hunk", { 1 }, "next hunk" },
    { mappings.prev_hunk, "jump_hunk", { -1 }, "previous hunk" },
    { mappings.next_diff_file, "jump_diff_file", { 1 }, "next changed file" },
    { mappings.prev_diff_file, "jump_diff_file", { -1 }, "previous changed file" },
    { mappings.toggle_diff, "toggle_diff_layout", {}, "toggle diff layout" },
    { mappings.stage, "stage", {}, "stage hunk" },
    { mappings.unstage, "unstage", {}, "unstage hunk" },
  }
  for _, item in ipairs(preview_actions) do
    local key, method, args, description = item[1], item[2], item[3], item[4]
    map(key, function()
      self[method](self, unpack(args))
    end, description, preview_buffers)
  end

  map(mappings.focus_files, function()
    self:focus_panel(self.active_panel)
  end, "focus active panel")
  map(mappings.focus_preview, function()
    self.dashboard:focus_preview()
  end, "focus preview")
  map("<Esc>", function()
    self:focus_panel(self.active_panel)
  end, "return to active panel", preview_buffers)

  for _, action in ipairs(actions.definitions()) do
    local key = mappings[action.mapping]
    local buffers = {}
    if action.global then
      buffers = all_buffers
    elseif action.panels then
      for _, id in ipairs(Dashboard.panel_order) do
        if action.panels[id] then
          buffers[#buffers + 1] = panel_buffers[id]
        end
      end
    elseif action.panel_only then
      for _, id in ipairs(Dashboard.panel_order) do
        buffers[#buffers + 1] = panel_buffers[id]
      end
    end
    if #buffers > 0 then
      local selected_action = action
      map(key, function()
        local method = self[selected_action.method]
        if method then
          method(self, unpack(selected_action.args or {}))
        end
      end, action.label:lower(), buffers)
    end
  end
end

return M
