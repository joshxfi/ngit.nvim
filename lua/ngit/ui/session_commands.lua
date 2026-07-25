local branch_backend = require("ngit.git.branch")
local conflict_backend = require("ngit.git.conflict")
local log_backend = require("ngit.git.log")
local mutate = require("ngit.git.mutate")
local remote_backend = require("ngit.git.remote")
local sequencer_backend = require("ngit.git.sequencer")
local stash_backend = require("ngit.git.stash")

local M = {}

local function valid_window(window)
  return window and vim.api.nvim_win_is_valid(window)
end

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit" })
end

local function short_oid(oid)
  return oid and oid:sub(1, 8) or "????????"
end

local function entry_key(entry)
  if not entry then
    return nil
  elseif entry.kind == "commit" then
    return "commit\0" .. entry.commit.oid
  elseif entry.kind == "branch" then
    return "branch\0" .. entry.branch.refname
  elseif entry.kind == "stash" then
    return "stash\0" .. entry.stash.oid
  end
  return entry.section .. "\0" .. entry.file.path
end

--- A rename occupies two index slots, so every path-scoped mutation has to name
--- the old path as well or the untouched half survives as a phantom entry.
local function entry_paths(entry)
  if entry.file.old_path and entry.file.old_path ~= entry.file.path then
    return { entry.file.path, entry.file.old_path }
  end
  return { entry.file.path }
end

function M.after_mutation(self, ok, err)
  if not ok then
    self:set_result(err or "Git operation failed", false)
    notify(err or "Git operation failed", vim.log.levels.ERROR)
    return
  end
  -- A mutation may have rewritten files that are open elsewhere in the editor.
  pcall(vim.cmd, "checktime")
  self:set_result("Git operation completed", true)
  self:refresh()
end

--- Refuses to overwrite a file that has unsaved edits in a loaded buffer.
local function worktree_is_safe(self, paths)
  for _, path in ipairs(paths) do
    local buffer = vim.fn.bufnr(vim.fs.joinpath(self.root, path))
    if buffer ~= -1 and vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
      notify(("Save or discard the modified buffer for %s first"):format(path), vim.log.levels.WARN)
      return false
    end
  end
  return true
end

local function confirm(self, prompt, label, perform)
  if not self.config.confirm_discard then
    perform()
    return
  end
  vim.ui.select({ "Cancel", label }, { prompt = prompt }, function(choice)
    if choice == label then
      perform()
    end
  end)
end

function M.stage(self)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry or entry.section == "staged" then
    return
  end
  local patch = entry.section == "unstaged" and self:mutation_patch() or nil
  if patch then
    mutate.apply_cached(self.root, patch, false, function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  else
    mutate.stage_file(self.root, entry_paths(entry), function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  end
end

function M.unstage(self)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry or entry.section ~= "staged" then
    return
  end
  local patch = self:mutation_patch()
  if patch then
    mutate.apply_cached(self.root, patch, true, function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  else
    mutate.unstage_file(self.root, entry_paths(entry), function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  end
end

function M.stage_all(self)
  if self.active_panel ~= "status" then
    return
  end
  mutate.stage_all(self.root, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

function M.unstage_all(self)
  if self.active_panel ~= "status" then
    return
  end
  mutate.unstage_all(self.root, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

function M.discard(self)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.section == "conflict" then
    notify("Resolve the conflict with ours/theirs, or abort the operation", vim.log.levels.WARN)
    return
  end

  local paths = entry_paths(entry)
  if not worktree_is_safe(self, paths) then
    return
  end

  if entry.section == "untracked" then
    confirm(
      self,
      ("Delete untracked file %s? This cannot be undone."):format(entry.file.path),
      "Delete",
      function()
        mutate.remove_untracked(self.root, entry.file.path, function(ok, err)
          M.after_mutation(self, ok, err)
        end)
      end
    )
  elseif entry.section == "staged" then
    confirm(
      self,
      ("Discard staged and worktree changes in %s?"):format(entry.file.path),
      "Discard",
      function()
        mutate.discard_all_changes(self.root, paths, function(ok, err)
          M.after_mutation(self, ok, err)
        end)
      end
    )
  else
    confirm(self, ("Discard worktree changes in %s?"):format(entry.file.path), "Discard", function()
      mutate.discard_file(self.root, paths, function(ok, err)
        M.after_mutation(self, ok, err)
      end)
    end)
  end
end

function M.open_file(self)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry then
    return
  end
  local path = vim.fs.joinpath(self.root, entry.file.path)
  if not vim.uv.fs_stat(path) then
    notify("The selected file does not exist in the worktree", vim.log.levels.WARN)
    return
  end
  self:close()
  vim.cmd.edit(vim.fn.fnameescape(path))
end

function M.prompt_filter(self)
  local panel_id = self.active_panel
  local panel = self:active_state()
  vim.ui.input({
    prompt = ("Filter %s: "):format(panel_id),
    default = panel.filter or "",
  }, function(value)
    if value == nil or self.closed then
      return
    end
    panel.filter = value ~= "" and value or nil
    if panel_id == "status" then
      self:render_files()
    else
      self:render_collection(panel_id)
    end
    self:sync_active_aliases()
    self:load_preview()
  end)
end

function M.primary_action(self)
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.kind == "branch" then
    if entry.branch.current then
      notify("Already on " .. entry.branch.name)
      return
    end
    branch_backend.switch(self.root, entry.branch, function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  elseif entry.kind == "commit" then
    vim.fn.setreg("+", entry.commit.oid)
    notify("Copied " .. entry.commit.oid)
  elseif valid_window(self.preview_win) then
    vim.api.nvim_set_current_win(self.preview_win)
  end
end

function M.new_item(self)
  if self.active_panel == "branches" then
    vim.ui.input({ prompt = "New branch: " }, function(name)
      if not name or name == "" or self.closed then
        return
      end
      branch_backend.create(self.root, name, function(ok, err)
        M.after_mutation(self, ok, err)
      end)
    end)
  elseif self.active_panel == "stashes" then
    vim.ui.input({ prompt = "Stash message (optional): " }, function(message)
      if message == nil or self.closed then
        return
      end
      stash_backend.push(self.root, message, function(ok, err)
        M.after_mutation(self, ok, err)
      end)
    end)
  end
end

function M.delete_item(self)
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.kind == "branch" then
    if entry.branch.remote then
      notify("Deleting remote branches is not supported yet", vim.log.levels.WARN)
      return
    elseif entry.branch.current then
      notify("The current branch cannot be deleted", vim.log.levels.WARN)
      return
    end
    vim.ui.select({ "Cancel", "Delete" }, {
      prompt = ("Delete merged branch %s?"):format(entry.branch.name),
    }, function(choice)
      if choice == "Delete" then
        branch_backend.delete(self.root, entry.branch.name, false, function(ok, err)
          M.after_mutation(self, ok, err)
        end)
      end
    end)
  elseif entry.kind == "stash" then
    vim.ui.select({ "Cancel", "Drop" }, {
      prompt = ("Drop %s permanently?"):format(entry.stash.ref),
    }, function(choice)
      if choice == "Drop" then
        stash_backend.drop(self.root, entry.stash, function(ok, err)
          M.after_mutation(self, ok, err)
        end)
      end
    end)
  end
end

function M.apply_item(self, pop)
  local entry = self:selected_entry()
  if not entry or entry.kind ~= "stash" then
    return
  end
  local action = pop and stash_backend.pop or stash_backend.apply
  action(self.root, entry.stash, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

local function staged_summary(status)
  local staged, conflicts = 0, 0
  for _, file in ipairs(status and status.files or {}) do
    if file.kind == "conflict" then
      conflicts = conflicts + 1
    elseif file.index_status ~= "." and file.index_status ~= " " and file.index_status ~= "?" then
      staged = staged + 1
    end
  end
  return staged, conflicts
end

function M.prompt_commit(self, amend)
  if self.active_panel ~= "status" then
    return
  end
  if self.commit_editor and not self.commit_editor.closed then
    if valid_window(self.commit_editor.window) then
      vim.api.nvim_set_current_win(self.commit_editor.window)
    end
    return
  end

  -- Catch the two refusals git would only report after a message was typed.
  local staged, conflicts = staged_summary(self.status)
  if conflicts > 0 then
    notify(
      ("Resolve %d conflicted file%s before committing"):format(
        conflicts,
        conflicts == 1 and "" or "s"
      ),
      vim.log.levels.WARN
    )
    return
  end
  if staged == 0 and not amend and not self.operation then
    notify("Nothing is staged to commit", vim.log.levels.WARN)
    return
  end

  local function open_editor(message)
    if self.closed then
      return
    end
    local CommitEditor = require("ngit.ui.commit_editor")
    self.commit_editor = CommitEditor.new(self.root, {
      amend = amend,
      message = message,
      staged = staged,
      branch = self.status and self.status.branch or nil,
      on_complete = function()
        self.commit_editor = nil
        if not self.closed then
          self:refresh()
        end
      end,
    })
  end

  if amend then
    log_backend.head_message(self.root, function(message, err)
      if not message then
        local unborn = (err or ""):find("does not have any commits yet", 1, true)
        notify(
          unborn and "There is no commit to amend yet"
            or (err or "Unable to load the current commit message"),
          vim.log.levels.WARN
        )
        return
      end
      open_editor(message)
    end)
  else
    open_editor("")
  end
end

function M.load_more(self)
  local panel = self.panels.commits
  if self.active_panel ~= "commits" or not panel.has_more or panel.job then
    return
  end
  panel.request = panel.request + 1
  local request = panel.request
  local existing = #(panel.data or {})
  local job
  job = log_backend.list(self.root, {
    limit = self.config.commit_limit,
    skip = existing,
  }, function(items, has_more, err)
    if panel.job == job then
      panel.job = nil
    end
    if self.closed or request ~= panel.request then
      return
    end
    if not items then
      notify(err or "Unable to load more commits", vim.log.levels.ERROR)
      return
    end
    vim.list_extend(panel.data, items)
    panel.has_more = has_more == true
    self:render_collection("commits", entry_key(panel.entries[panel.selected]))
    self:update_actions()
  end)
  panel.job = job
end

local command_labels = {
  fetch = "git fetch --all --prune",
  pull = "git pull --ff-only",
  push = "git push",
}

function M.run_remote(self, operation)
  if self.remote_console and self.remote_console.running then
    notify("A remote operation is already running", vim.log.levels.WARN)
    return
  end
  local Console = require("ngit.ui.console")
  local console = Console.new(command_labels[operation])
  self.remote_console = console

  local transcript = {}
  local function on_chunk(stream, data)
    transcript[#transcript + 1] = data
    console:append(data, stream)
  end

  local function settle(ok, code)
    console:finish(ok, code)
    self:set_result(
      ok and (operation .. " completed") or (operation .. (" failed (%d)"):format(code)),
      ok
    )
    if self.remote_console == console then
      self.remote_console = nil
    end
    if ok and not self.closed then
      self:refresh()
    end
  end

  console.process = remote_backend.run(self.root, operation, on_chunk, function(ok, result)
    -- A first push from a fresh branch fails purely because no upstream is set.
    -- Offering to set it here saves dropping to a shell for the common case.
    if
      ok
      or operation ~= "push"
      or self.closed
      or not remote_backend.missing_upstream(table.concat(transcript))
    then
      settle(ok, result.code)
      return
    end
    remote_backend.default_remote(self.root, function(remote, err)
      if not remote then
        console:append("\n" .. (err or "No remote is configured") .. "\n", "stderr")
        settle(false, result.code)
        return
      end
      local branch = self.status and self.status.branch or "HEAD"
      vim.ui.select({ "Cancel", "Set upstream and push" }, {
        prompt = ("%s has no upstream. Push and track %s/%s?"):format(branch, remote, branch),
      }, function(choice)
        if choice ~= "Set upstream and push" or self.closed then
          settle(false, result.code)
          return
        end
        console:append(("\n$ git push --set-upstream %s HEAD\n"):format(remote), "stdout")
        console.running = true
        console.process = remote_backend.push_set_upstream(
          self.root,
          remote,
          on_chunk,
          function(retry_ok, retry_result)
            settle(retry_ok, retry_result.code)
          end
        )
      end)
    end)
  end)
end

function M.choose_conflict(self, side)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry or entry.section ~= "conflict" then
    return
  end
  conflict_backend.choose(self.root, entry.file.path, side, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

function M.run_sequencer(self, action)
  if not self.operation then
    notify("No merge, rebase, cherry-pick, or revert is in progress", vim.log.levels.WARN)
    return
  end
  local function perform()
    sequencer_backend.run(self.root, self.operation, action, function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  end
  if action == "abort" then
    vim.ui.select({ "Cancel", "Abort" }, {
      prompt = ("Abort the current %s?"):format(self.operation),
    }, function(choice)
      if choice == "Abort" then
        perform()
      end
    end)
  else
    perform()
  end
end

function M.start_operation(self, operation)
  local entry = self:selected_entry()
  local target
  local description
  if operation == "cherry-pick" and entry and entry.kind == "commit" then
    target = entry.commit.oid
    description = ("Cherry-pick %s?"):format(short_oid(target))
  elseif (operation == "merge" or operation == "rebase") and entry and entry.kind == "branch" then
    if entry.branch.current then
      notify("Select a different branch", vim.log.levels.WARN)
      return
    end
    target = entry.branch.oid
    description = operation == "merge"
        and ("Merge %s into the current branch?"):format(entry.branch.name)
      or ("Rebase the current branch onto %s?"):format(entry.branch.name)
  else
    return
  end

  vim.ui.select({ "Cancel", "Continue" }, { prompt = description }, function(choice)
    if choice ~= "Continue" then
      return
    end
    sequencer_backend.start(self.root, operation, target, function(ok, err)
      if ok then
        self:refresh()
        return
      end
      sequencer_backend.detect(self.root, function(active)
        if active then
          notify(("%s stopped for conflict resolution"):format(active), vim.log.levels.WARN)
          if self.active_panel == "status" then
            self:refresh()
          else
            self:switch_view("status")
          end
        else
          notify(err or ("Unable to start " .. operation), vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

return M
