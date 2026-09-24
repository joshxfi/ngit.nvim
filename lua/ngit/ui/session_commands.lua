local branch_backend = require("ngit.git.branch")
local conflict_backend = require("ngit.git.conflict")
local log_backend = require("ngit.git.log")
local mutate = require("ngit.git.mutate")
local remote_backend = require("ngit.git.remote")
local sequencer_backend = require("ngit.git.sequencer")
local stash_backend = require("ngit.git.stash")
local Steps = require("ngit.util.steps")

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

--- Deduplicated paths of the accepted entries. A multi-row selection can name
--- the same file twice, once staged and once unstaged, and passing a path twice
--- to a pathspec makes Git do the work twice.
local function collect_paths(entries, accept)
  local paths, seen = {}, {}
  for _, entry in ipairs(entries) do
    if entry.file and (not accept or accept(entry)) then
      for _, path in ipairs(entry_paths(entry)) do
        if not seen[path] then
          seen[path] = true
          paths[#paths + 1] = path
        end
      end
    end
  end
  return paths
end

local function group_by_section(entries)
  local groups = {}
  for _, entry in ipairs(entries) do
    if entry.file and entry.section then
      groups[entry.section] = groups[entry.section] or {}
      table.insert(groups[entry.section], entry)
    end
  end
  return groups
end

--- Rereads every loaded buffer whose file changed on disk. Anything that can
--- rewrite the worktree calls this, including operations that stop for conflicts,
--- so an open buffer never shows content git has already replaced.
function M.reload_buffers()
  pcall(vim.cmd, "checktime")
end

function M.after_mutation(self, ok, err)
  if not ok then
    self:set_result(err or "Git operation failed", false)
    notify(err or "Git operation failed", vim.log.levels.ERROR)
    return
  end
  -- A mutation may have rewritten files that are open elsewhere in the editor.
  M.reload_buffers()
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

M.worktree_is_safe = worktree_is_safe

--- The same refusal for operations that can rewrite any file in the worktree,
--- such as a hard reset: every loaded, modified buffer under the root counts.
function M.worktree_has_no_unsaved_buffers(self)
  local root = vim.uv.fs_realpath(self.root) or self.root
  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buffer) and vim.bo[buffer].modified then
      local name = vim.api.nvim_buf_get_name(buffer)
      local real = name ~= "" and (vim.uv.fs_realpath(name) or name) or ""
      if vim.startswith(real, root .. "/") then
        notify(
          ("Save or discard the modified buffer for %s first"):format(real:sub(#root + 2)),
          vim.log.levels.WARN
        )
        return false
      end
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
  if self.active_panel ~= "status" or self:review_only() then
    return
  end
  local entries = self:selected_entries()
  if #entries == 0 then
    return
  end
  local function settle(ok, err)
    M.after_mutation(self, ok, err)
  end

  if #entries > 1 then
    local paths = collect_paths(entries, function(entry)
      return entry.section ~= "staged"
    end)
    if #paths == 0 then
      notify("Every selected change is already staged")
      return
    end
    mutate.stage_file(self.root, paths, settle)
    return
  end

  local entry = entries[1]
  if entry.section == "staged" then
    return
  end
  if entry.section == "unstaged" then
    local patch, err = self:selection_patch(false)
    if err then
      notify(err, vim.log.levels.WARN)
      return
    end
    if patch then
      mutate.apply(self.root, patch, { target = "index" }, settle)
      return
    end
  end
  mutate.stage_file(self.root, entry_paths(entry), settle)
end

function M.unstage(self)
  if self.active_panel ~= "status" or self:review_only() then
    return
  end
  local entries = self:selected_entries()
  if #entries == 0 then
    return
  end
  local function settle(ok, err)
    M.after_mutation(self, ok, err)
  end

  if #entries > 1 then
    local paths = collect_paths(entries, function(entry)
      return entry.section == "staged"
    end)
    if #paths == 0 then
      notify("None of the selected changes are staged", vim.log.levels.WARN)
      return
    end
    mutate.unstage_file(self.root, paths, settle)
    return
  end

  local entry = entries[1]
  if entry.section ~= "staged" then
    return
  end
  local patch, err = self:selection_patch(true)
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end
  if patch then
    mutate.apply(self.root, patch, { reverse = true, target = "index" }, settle)
    return
  end
  mutate.unstage_file(self.root, entry_paths(entry), settle)
end

function M.stage_all(self)
  if self.active_panel ~= "status" or self:review_only() then
    return
  end
  mutate.stage_all(self.root, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

function M.unstage_all(self)
  if self.active_panel ~= "status" or self:review_only() then
    return
  end
  mutate.unstage_all(self.root, function(ok, err)
    M.after_mutation(self, ok, err)
  end)
end

--- Discards a mixed selection. Each section needs a different command, so the
--- groups run in sequence and the first failure is what gets reported.
local function discard_many(self, entries, settle)
  local groups = group_by_section(entries)
  if groups.conflict then
    notify("Leave the conflicted files out of the selection", vim.log.levels.WARN)
    return
  end
  local paths = collect_paths(entries)
  if #paths == 0 or not worktree_is_safe(self, paths) then
    return
  end

  local staged = groups.staged and collect_paths(groups.staged) or {}
  local unstaged = groups.unstaged and collect_paths(groups.unstaged) or {}
  local untracked = groups.untracked and collect_paths(groups.untracked) or {}

  local summary = {}
  if #staged > 0 then
    summary[#summary + 1] = ("%d staged"):format(#staged)
  end
  if #unstaged > 0 then
    summary[#summary + 1] = ("%d unstaged"):format(#unstaged)
  end
  if #untracked > 0 then
    summary[#summary + 1] = ("%d untracked (deleted)"):format(#untracked)
  end

  confirm(
    self,
    ("Discard %s? This cannot be undone."):format(table.concat(summary, ", ")),
    "Discard",
    function()
      local steps = {}
      if #staged > 0 then
        steps[#steps + 1] = function(done)
          mutate.discard_all_changes(self.root, staged, done)
        end
      end
      if #unstaged > 0 then
        steps[#steps + 1] = function(done)
          mutate.discard_file(self.root, unstaged, done)
        end
      end
      if #untracked > 0 then
        steps[#steps + 1] = function(done)
          mutate.remove_untracked(self.root, untracked, done)
        end
      end
      Steps.run(steps, settle)
    end
  )
end

function M.discard(self)
  if self.active_panel ~= "status" or self:review_only() then
    return
  end
  local entries = self:selected_entries()
  if #entries == 0 then
    return
  end
  local function settle(ok, err)
    M.after_mutation(self, ok, err)
  end
  if #entries > 1 then
    discard_many(self, entries, settle)
    return
  end

  local entry = entries[1]
  if entry.section == "conflict" then
    notify("Resolve the conflict with ours/theirs, or abort the operation", vim.log.levels.WARN)
    return
  end

  -- Hunk or line scope, when the action was invoked from the diff pane. An
  -- untracked file has no old side to restore a range from, so it is only ever
  -- discarded whole.
  local patch, patch_err
  if entry.section ~= "untracked" then
    patch, patch_err = self:selection_patch(true)
    if patch_err then
      notify(patch_err, vim.log.levels.WARN)
      return
    end
  end

  local paths = entry_paths(entry)
  if not worktree_is_safe(self, paths) then
    return
  end

  if patch then
    local target = entry.section == "staged" and "both" or "worktree"
    confirm(
      self,
      ("Discard the selected change in %s?"):format(entry.file.path),
      "Discard",
      function()
        mutate.apply(self.root, patch, { reverse = true, target = target }, settle)
      end
    )
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

--- Opens the reviewed file. Invoked from the diff it uses the path and source
--- line under the cursor, so `o` lands where the reader was looking rather than
--- at the top of the file; invoked from the panel it opens the selected entry.
function M.open_file(self)
  local path, line = self:preview_location()
  if not path then
    if self.active_panel ~= "status" then
      return
    end
    local entry = self:selected_entry()
    if not entry then
      return
    end
    path = entry.file.path
  end

  local absolute = vim.fs.joinpath(self.root, path)
  if not vim.uv.fs_stat(absolute) then
    notify("The selected file does not exist in the worktree", vim.log.levels.WARN)
    return
  end
  self:close()
  vim.cmd.edit(vim.fn.fnameescape(absolute))
  if line then
    -- A file whose worktree copy has moved on may be shorter than the diff said,
    -- so an out-of-range line is not an error worth reporting.
    if pcall(vim.api.nvim_win_set_cursor, 0, { line, 0 }) then
      vim.cmd("normal! zz")
    end
  end
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

--- Creates a branch. The start point is whatever the reader is pointing at, so
--- `n` on a commit branches from that commit rather than silently from HEAD, and
--- the prompt says which.
local function new_branch(self, start_point, label)
  local prompt = start_point and ("New branch at %s: "):format(label) or "New branch: "
  vim.ui.input({ prompt = prompt }, function(name)
    if not name or name == "" or self.closed then
      return
    end
    branch_backend.create(self.root, name, start_point, function(ok, err)
      M.after_mutation(self, ok, err)
    end)
  end)
end

function M.new_item(self)
  local entry = self:selected_entry()
  if self.active_panel == "commits" then
    if not entry then
      return
    end
    new_branch(self, entry.commit.oid, entry.commit.oid:sub(1, 8))
  elseif self.active_panel == "branches" then
    if entry and entry.kind == "branch" and not entry.branch.current then
      new_branch(self, entry.branch.refname, entry.branch.name)
    else
      new_branch(self, nil, nil)
    end
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

--- Deleting an unmerged branch is refused by git rather than by ngit, and the
--- refusal is the prompt: it names the branch as unmerged and offers the forced
--- delete as a second, explicit choice.
local function delete_branch(self, name)
  branch_backend.delete(self.root, name, false, function(ok, err)
    if ok then
      M.after_mutation(self, true, nil)
      return
    end
    local unmerged = (err or ""):find("not fully merged", 1, true)
    if not unmerged then
      M.after_mutation(self, false, err)
      return
    end
    vim.ui.select({ "Cancel", "Delete anyway" }, {
      prompt = ("%s is not fully merged. Delete it and lose its commits?"):format(name),
    }, function(choice)
      if choice ~= "Delete anyway" then
        self:set_result(err, false)
        return
      end
      branch_backend.delete(self.root, name, true, function(forced, force_err)
        M.after_mutation(self, forced, force_err)
      end)
    end)
  end)
end

local function delete_remote_branch(self, entry)
  local remote, branch = branch_backend.split_remote(entry.branch.name)
  if not remote then
    notify("This ref does not name a remote to delete from", vim.log.levels.WARN)
    return
  end
  vim.ui.select({ "Cancel", "Delete on the remote" }, {
    prompt = ("Delete %s from %s? This affects everyone using it."):format(branch, remote),
  }, function(choice)
    if choice ~= "Delete on the remote" then
      return
    end
    M.run_remote_args(
      self,
      branch_backend.delete_remote_args(remote, branch),
      ("git push --delete %s %s"):format(remote, branch)
    )
  end)
end

function M.delete_item(self)
  local entry = self:selected_entry()
  if not entry then
    return
  end
  if entry.kind == "branch" then
    if entry.branch.tag then
      vim.ui.select({ "Cancel", "Delete" }, {
        prompt = ("Delete the tag %s?"):format(entry.branch.name),
      }, function(choice)
        if choice == "Delete" then
          branch_backend.delete_tag(self.root, entry.branch.name, function(ok, err)
            M.after_mutation(self, ok, err)
          end)
        end
      end)
      return
    end
    if entry.branch.remote then
      delete_remote_branch(self, entry)
      return
    end
    if entry.branch.current then
      notify("The current branch cannot be deleted", vim.log.levels.WARN)
      return
    end
    vim.ui.select({ "Cancel", "Delete" }, {
      prompt = ("Delete branch %s?"):format(entry.branch.name),
    }, function(choice)
      if choice == "Delete" then
        delete_branch(self, entry.branch.name)
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

--- `options` is a bare boolean for the plain commit and amend keys, and the table
--- form when the commit menu has chosen switches.
---@param self table
---@param options boolean|NgitCommitOptions
function M.prompt_commit(self, options)
  -- The plain commit keys belong to the Changes panel; the commit menu is global,
  -- and a switch chosen there has to work from whichever panel it was opened in.
  if self.active_panel ~= "status" and type(options) ~= "table" then
    return
  end
  local commit_options = type(options) == "table" and vim.deepcopy(options)
    or { amend = options == true }
  local amend = commit_options.amend == true
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
  if staged == 0 and not amend and not self.operation and not commit_options.allow_empty then
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
      commit_options = commit_options,
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
  local options = require("ngit.ui.session_refresh").commit_options(self, existing)
  job = log_backend.list(self.root, options, function(items, has_more, err)
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

--- Runs a network command in a streaming console.
---
--- Every variant the remote menu offers arrives here, so the console header shows
--- the exact command rather than a friendly name for it, and the missing-upstream
--- retry covers any push rather than only the default one.
---@param args string[]
---@param label string
function M.run_remote_args(self, args, label)
  if self.remote_console and self.remote_console.running then
    notify("A remote operation is already running", vim.log.levels.WARN)
    return
  end
  local Console = require("ngit.ui.console")
  local console = Console.new(label)
  self.remote_console = console

  local transcript = {}
  local function on_chunk(stream, data)
    transcript[#transcript + 1] = data
    console:append(data, stream)
  end

  local function settle(ok, code)
    M.reload_buffers()
    console:finish(ok, code)
    self:set_result(ok and (label .. " completed") or (label .. (" failed (%d)"):format(code)), ok)
    if self.remote_console == console then
      self.remote_console = nil
    end
    if ok and not self.closed then
      self:refresh()
    end
  end

  console.process = remote_backend.stream(self.root, args, on_chunk, function(ok, result)
    -- A first push from a fresh branch fails purely because no upstream is set.
    -- Offering to set it here saves dropping to a shell for the common case.
    if
      ok
      or args[1] ~= "push"
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

function M.run_remote(self, operation)
  M.run_remote_args(self, remote_backend.operations[operation], command_labels[operation])
end

--- Takes a side for a conflict.
---
--- Invoked from the diff it resolves the one block the cursor sits in, so a file
--- with several conflicts can take ours here and theirs there; invoked from the
--- panel it takes that side for the whole file. Only the whole-file case can go
--- through `git checkout --ours`, which restores the recorded stage exactly,
--- including a file one side deleted.
---@param side "ours"|"theirs"|"both"
function M.choose_conflict(self, side)
  if self.active_panel ~= "status" then
    return
  end
  local entry = self:selected_entry()
  if not entry or entry.section ~= "conflict" then
    return
  end
  local function settle(ok, err)
    M.after_mutation(self, ok, err)
  end
  if not worktree_is_safe(self, { entry.file.path }) then
    return
  end

  local _, line = self:preview_location()
  if line then
    conflict_backend.resolve(self.root, entry.file.path, side, line, settle)
    return
  end
  conflict_backend.choose(self.root, entry.file.path, side, settle)
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
      M.reload_buffers()
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
