local M = {}

local function panels(...)
  local result = {}
  for _, name in ipairs({ ... }) do
    result[name] = true
  end
  return result
end

local definitions = {
  {
    id = "stage",
    mapping = "stage",
    label = "Stage",
    panels = panels("status"),
    method = "stage",
    enabled = function(context)
      return context.entry and context.entry.section ~= "staged"
    end,
  },
  {
    id = "unstage",
    mapping = "unstage",
    label = "Unstage",
    panels = panels("status"),
    method = "unstage",
    enabled = function(context)
      return context.entry and context.entry.section == "staged"
    end,
  },
  {
    id = "discard",
    mapping = "discard",
    label = "Discard",
    panels = panels("status"),
    method = "discard",
    enabled = function(context)
      return context.entry
        and context.entry.section == "unstaged"
        and context.entry.file.kind ~= "untracked"
    end,
  },
  {
    id = "open",
    mapping = "open_file",
    label = "Open",
    panels = panels("status"),
    method = "open_file",
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "commit",
    mapping = "commit",
    label = "Commit",
    panels = panels("status"),
    method = "prompt_commit",
    args = { false },
  },
  {
    id = "amend",
    mapping = "amend",
    label = "Amend",
    panels = panels("status"),
    method = "prompt_commit",
    args = { true },
  },
  {
    id = "ours",
    mapping = "choose_ours",
    label = "Ours",
    panels = panels("status"),
    method = "choose_conflict",
    args = { "ours" },
    enabled = function(context)
      return context.entry and context.entry.section == "conflict"
    end,
  },
  {
    id = "theirs",
    mapping = "choose_theirs",
    label = "Theirs",
    panels = panels("status"),
    method = "choose_conflict",
    args = { "theirs" },
    enabled = function(context)
      return context.entry and context.entry.section == "conflict"
    end,
  },
  {
    id = "continue",
    mapping = "continue_operation",
    label = "Continue",
    panels = panels("status"),
    method = "run_sequencer",
    args = { "continue" },
    enabled = function(context)
      return context.operation ~= nil
    end,
  },
  {
    id = "abort",
    mapping = "abort_operation",
    label = "Abort",
    panels = panels("status"),
    method = "run_sequencer",
    args = { "abort" },
    enabled = function(context)
      return context.operation ~= nil
    end,
  },
  {
    id = "primary",
    mapping = "primary_action",
    label = "Checkout",
    panels = panels("branches"),
    method = "primary_action",
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "new_branch",
    mapping = "new_item",
    label = "New",
    panels = panels("branches"),
    method = "new_item",
  },
  {
    id = "delete_branch",
    mapping = "delete_item",
    label = "Delete",
    panels = panels("branches"),
    method = "delete_item",
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "merge",
    mapping = "merge",
    label = "Merge",
    panels = panels("branches"),
    method = "start_operation",
    args = { "merge" },
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "rebase",
    mapping = "rebase",
    label = "Rebase",
    panels = panels("branches"),
    method = "start_operation",
    args = { "rebase" },
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "copy",
    mapping = "primary_action",
    label = "Copy SHA",
    panels = panels("commits"),
    method = "primary_action",
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "cherry_pick",
    mapping = "cherry_pick",
    label = "Cherry-pick",
    panels = panels("commits"),
    method = "start_operation",
    args = { "cherry-pick" },
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "load_more",
    mapping = "load_more",
    label = "More",
    panels = panels("commits"),
    method = "load_more",
    enabled = function(context)
      return context.has_more == true
    end,
  },
  {
    id = "new_stash",
    mapping = "new_item",
    label = "New",
    panels = panels("stashes"),
    method = "new_item",
  },
  {
    id = "apply",
    mapping = "apply_item",
    label = "Apply",
    panels = panels("stashes"),
    method = "apply_item",
    args = { false },
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "pop",
    mapping = "pop_item",
    label = "Pop",
    panels = panels("stashes"),
    method = "apply_item",
    args = { true },
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "drop",
    mapping = "delete_item",
    label = "Drop",
    panels = panels("stashes"),
    method = "delete_item",
    enabled = function(context)
      return context.entry ~= nil
    end,
  },
  {
    id = "filter",
    mapping = "filter",
    label = "Filter",
    method = "prompt_filter",
    panel_only = true,
  },
  {
    id = "fetch",
    mapping = "fetch",
    label = "Fetch",
    method = "run_remote",
    args = { "fetch" },
    global = true,
  },
  {
    id = "pull",
    mapping = "pull",
    label = "Pull",
    method = "run_remote",
    args = { "pull" },
    global = true,
  },
  {
    id = "push",
    mapping = "push",
    label = "Push",
    method = "run_remote",
    args = { "push" },
    global = true,
  },
  { id = "refresh", mapping = "refresh", label = "Refresh", method = "refresh", global = true },
  { id = "help", mapping = "help", label = "Help", method = "show_help", global = true },
  { id = "close", mapping = "close", label = "Close", method = "close", global = true },
}

local function applies(action, context)
  if action.panels and not action.panels[context.panel] then
    return false
  end
  if action.enabled and not action.enabled(context) then
    return false
  end
  return true
end

function M.definitions()
  return definitions
end

function M.for_context(context, mappings)
  local specific = {}
  local global = {}
  for _, action in ipairs(definitions) do
    local key = mappings[action.mapping]
    if key and key ~= false and key ~= "" and applies(action, context) then
      local item = {
        id = action.id,
        key = key,
        label = action.label,
        method = action.method,
        args = action.args,
      }
      if action.global then
        global[#global + 1] = item
      else
        specific[#specific + 1] = item
      end
    end
  end
  vim.list_extend(specific, global)
  return specific
end

function M.help_items(mappings)
  local by_mapping = {}
  local result = {}
  for _, action in ipairs(definitions) do
    local key = mappings[action.mapping]
    if key and key ~= false and key ~= "" then
      local item = by_mapping[action.mapping]
      if not item then
        item = { key = key, labels = {}, seen = {} }
        by_mapping[action.mapping] = item
        result[#result + 1] = item
      end
      if not item.seen[action.label] then
        item.seen[action.label] = true
        item.labels[#item.labels + 1] = action.label
      end
    end
  end
  for _, item in ipairs(result) do
    item.label = table.concat(item.labels, " / ")
    item.labels = nil
    item.seen = nil
  end
  return result
end

return M
