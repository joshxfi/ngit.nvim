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

  local function map(key, callback, description, buffers, mode)
    if not key or key == false or key == "" then
      return
    end
    for _, buffer in ipairs(buffers or all_buffers) do
      vim.keymap.set(mode or "n", key, callback, {
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
    { mappings.next_conflict, "jump_conflict", { 1 }, "next conflict" },
    { mappings.prev_conflict, "jump_conflict", { -1 }, "previous conflict" },
    { mappings.toggle_diff, "toggle_diff_layout", {}, "toggle diff layout" },
    { mappings.stage, "stage", {}, "stage hunk" },
    { mappings.unstage, "unstage", {}, "unstage hunk" },
    { mappings.discard, "discard", {}, "discard hunk" },
    { mappings.open_file, "open_file", {}, "open file at line" },
    { mappings.blame, "blame", {}, "blame this file" },
    { mappings.file_history, "file_history", {}, "history of this file" },
    { mappings.copy_menu, "copy_menu", {}, "copy" },
    -- Taking a side from the diff resolves the block under the cursor, so these
    -- belong here as well as on the panel.
    { mappings.choose_ours, "choose_conflict", { "ours" }, "take ours" },
    { mappings.choose_theirs, "choose_conflict", { "theirs" }, "take theirs" },
    { mappings.choose_both, "choose_conflict", { "both" }, "take both" },
  }
  for _, item in ipairs(preview_actions) do
    local key, method, args, description = item[1], item[2], item[3], item[4]
    map(key, function()
      self[method](self, unpack(args))
    end, description, preview_buffers)
  end

  -- Line-scoped variants. The same entry points are reused: they ask the session
  -- for the selection, so a visual range narrows the patch instead of taking the
  -- whole hunk. Panel buffers get them too, where a range means several files.
  local visual_targets = vim.list_extend({ panel_buffers.status }, preview_buffers)
  for _, item in ipairs({
    { mappings.stage, "stage", "stage selection" },
    { mappings.unstage, "unstage", "unstage selection" },
    { mappings.discard, "discard", "discard selection" },
  }) do
    local key, method, description = item[1], item[2], item[3]
    map(key, function()
      self[method](self)
    end, description, visual_targets, "x")
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
