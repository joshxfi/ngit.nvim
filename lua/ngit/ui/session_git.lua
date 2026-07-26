local blame_backend = require("ngit.git.blame")
local branch_backend = require("ngit.git.branch")
local conflict_backend = require("ngit.git.conflict")
local log_backend = require("ngit.git.log")
local mutate = require("ngit.git.mutate")
local range_backend = require("ngit.git.range")
local remote_backend = require("ngit.git.remote")
local sequencer_backend = require("ngit.git.sequencer")
local stash_backend = require("ngit.git.stash")
local submodule_backend = require("ngit.git.submodule")
local worktree_backend = require("ngit.git.worktree")
local Menu = require("ngit.ui.menu")

local M = {}

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "ngit" })
end

local function short_oid(oid)
  return oid and oid:sub(1, 8) or "????????"
end

local function settler(self)
  return function(ok, err)
    self.after_mutation(self, ok, err)
  end
end

--- Revision the reader is pointing at, whichever panel they are in. Menus name
--- it back to them, so it has to be the same answer the action will use.
---@return string? revision, string? label
local function selected_revision(self)
  local entry = self:selected_entry()
  if not entry then
    return nil, nil
  end
  if entry.kind == "commit" then
    return entry.commit.oid, ("%s %s"):format(short_oid(entry.commit.oid), entry.commit.subject)
  elseif entry.kind == "branch" then
    return entry.branch.oid, entry.branch.name
  elseif entry.kind == "stash" then
    return entry.stash.oid, entry.stash.ref
  end
  return nil, nil
end

--- Path the reader is pointing at: the file under the diff cursor when the diff
--- has focus, otherwise the selected entry.
---@return string?
local function selected_path(self)
  local path = self:preview_location()
  if path then
    return path
  end
  local entry = self:selected_entry()
  if entry and entry.file then
    return entry.file.path
  end
  return nil
end

-- Commits ---------------------------------------------------------------------

function M.revert(self)
  local entry = self:selected_entry()
  if not entry or entry.kind ~= "commit" then
    return
  end
  Menu.confirm(
    ("Revert %s? A new commit undoes it."):format(short_oid(entry.commit.oid)),
    "Revert",
    function()
      sequencer_backend.start(self.root, "revert", entry.commit.oid, function(ok, err)
        if ok then
          self:refresh()
          return
        end
        -- A conflicted revert is a working state rather than a failure, so the
        -- sequencer is asked what is actually in progress before reporting.
        sequencer_backend.detect(self.root, function(active)
          if active then
            notify("revert stopped for conflict resolution", vim.log.levels.WARN)
            self:switch_view("status")
          else
            notify(err or "Unable to revert", vim.log.levels.ERROR)
          end
        end)
      end)
    end
  )
end

local reset_modes = {
  {
    mode = "soft",
    label = "Soft",
    detail = "move HEAD, keep the index and the worktree",
  },
  {
    mode = "mixed",
    label = "Mixed",
    detail = "move HEAD, unstage, keep the worktree",
  },
  {
    mode = "hard",
    label = "Hard",
    detail = "move HEAD and discard every change",
    destructive = true,
  },
}

function M.reset(self)
  local revision, label = selected_revision(self)
  if not revision then
    notify("Select a commit or branch to reset onto", vim.log.levels.WARN)
    return
  end
  local items = {}
  for _, mode in ipairs(reset_modes) do
    items[#items + 1] = {
      label = ("git reset --%s"):format(mode.mode),
      detail = mode.detail,
      action = function()
        local function perform()
          mutate.reset(self.root, mode.mode, revision, settler(self))
        end
        if mode.destructive then
          Menu.confirm(
            ("Hard reset to %s? Every uncommitted change is lost."):format(label),
            "Discard and reset",
            perform
          )
        else
          perform()
        end
      end,
    }
  end
  Menu.choose(("Reset onto %s"):format(label), items)
end

function M.checkout_commit(self)
  local revision, label = selected_revision(self)
  if not revision then
    return
  end
  Menu.confirm(("Check out %s with a detached HEAD?"):format(label), "Detach HEAD", function()
    branch_backend.detach(self.root, revision, settler(self))
  end)
end

function M.tag(self)
  local revision, label = selected_revision(self)
  revision = revision or "HEAD"
  label = label or "HEAD"
  Menu.ask(("Tag name for %s: "):format(label), nil, function(name)
    vim.ui.input({ prompt = "Tag message (empty for lightweight): " }, function(message)
      if message == nil then
        return
      end
      branch_backend.create_tag(self.root, name, revision, message, settler(self))
    end)
  end)
end

-- Interactive rebase ----------------------------------------------------------

local function open_rebase_editor(self, base, label)
  sequencer_backend.rebase_todo(self.root, base, function(steps, err)
    if not steps then
      notify(err or "Unable to read the rebase plan", vim.log.levels.ERROR)
      return
    end
    if #steps == 0 then
      notify(("There is nothing to replay onto %s"):format(label), vim.log.levels.WARN)
      return
    end
    if self.rebase_editor and not self.rebase_editor.closed then
      self.rebase_editor:focus()
      return
    end
    local RebaseEditor = require("ngit.ui.rebase_editor")
    self.rebase_editor = RebaseEditor.new({
      base = base,
      label = label,
      steps = steps,
      on_submit = function(plan)
        sequencer_backend.rebase_with_todo(self.root, base, plan, function(ok, rebase_err)
          if ok then
            self:refresh()
            return
          end
          sequencer_backend.detect(self.root, function(active)
            if active then
              notify(
                ("%s stopped; amend or resolve, then continue"):format(active),
                vim.log.levels.WARN
              )
              self:switch_view("status")
            else
              notify(rebase_err or "Unable to rebase", vim.log.levels.ERROR)
            end
          end)
        end)
      end,
      on_close = function()
        self.rebase_editor = nil
      end,
    })
  end)
end

function M.interactive_rebase(self)
  local entry = self:selected_entry()
  local items = {}

  if entry and entry.kind == "commit" then
    local oid = entry.commit.oid
    items[#items + 1] = {
      label = "Edit the plan from this commit",
      detail = ("replay %s..HEAD"):format(short_oid(oid)),
      action = function()
        open_rebase_editor(self, oid .. "~1", short_oid(oid) .. "~1")
      end,
    }
    items[#items + 1] = {
      label = "Autosquash from this commit",
      detail = "fold fixup! and squash! commits in",
      action = function()
        sequencer_backend.rebase_autosquash(self.root, oid .. "~1", settler(self))
      end,
    }
  end
  if entry and entry.kind == "branch" and not entry.branch.current then
    local name = entry.branch.name
    items[#items + 1] = {
      label = ("Edit the plan onto %s"):format(name),
      detail = ("replay %s..HEAD"):format(name),
      action = function()
        open_rebase_editor(self, entry.branch.refname, name)
      end,
    }
  end

  items[#items + 1] = {
    label = "Edit the plan onto the upstream",
    detail = "replay everything this branch adds",
    action = function()
      range_backend.review_spec(self.root, function(spec, err)
        if not spec then
          notify(err or "No upstream to rebase onto", vim.log.levels.WARN)
          return
        end
        local base = spec:gsub("%.%.%.HEAD$", "")
        open_rebase_editor(self, base, base)
      end)
    end,
  }
  items[#items + 1] = {
    label = "Autosquash onto the upstream",
    detail = "fold fixup! and squash! commits in",
    action = function()
      range_backend.review_spec(self.root, function(spec, err)
        if not spec then
          notify(err or "No upstream to rebase onto", vim.log.levels.WARN)
          return
        end
        sequencer_backend.rebase_autosquash(
          self.root,
          (spec:gsub("%.%.%.HEAD$", "")),
          settler(self)
        )
      end)
    end,
  }
  Menu.choose("Interactive rebase", items)
end

-- Branches --------------------------------------------------------------------

function M.rename_item(self)
  local entry = self:selected_entry()
  if not entry or entry.kind ~= "branch" then
    return
  end
  if entry.branch.remote then
    notify("Rename the branch locally, then push it and delete the old name", vim.log.levels.WARN)
    return
  end
  if entry.branch.tag then
    notify("Git has no tag rename; create the new tag and delete the old one", vim.log.levels.WARN)
    return
  end
  Menu.ask(("Rename %s to: "):format(entry.branch.name), entry.branch.name, function(name)
    branch_backend.rename(self.root, entry.branch.name, name, settler(self))
  end)
end

function M.set_upstream(self)
  local entry = self:selected_entry()
  local branch = self.status and self.status.branch
  if entry and entry.kind == "branch" and not entry.branch.remote and not entry.branch.tag then
    branch = entry.branch.name
  end
  if not branch or branch == "" then
    notify("HEAD is detached, so there is no branch to track with", vim.log.levels.WARN)
    return
  end

  local items = {}
  if entry and entry.kind == "branch" and entry.branch.remote then
    items[#items + 1] = {
      label = ("Track %s"):format(entry.branch.name),
      detail = ("%s follows it"):format(branch),
      action = function()
        branch_backend.set_upstream(self.root, branch, entry.branch.name, settler(self))
      end,
    }
  end
  items[#items + 1] = {
    label = "Track another ref…",
    action = function()
      Menu.ask(("Upstream for %s: "):format(branch), nil, function(upstream)
        branch_backend.set_upstream(self.root, branch, upstream, settler(self))
      end)
    end,
  }
  items[#items + 1] = {
    label = "Stop tracking anything",
    detail = ("%s loses its upstream"):format(branch),
    action = function()
      branch_backend.set_upstream(self.root, branch, nil, settler(self))
    end,
  }
  Menu.choose(("Upstream for %s"):format(branch), items)
end

-- Remotes ---------------------------------------------------------------------

local function run_variant(self, variant)
  local function start(args, label)
    self:run_remote_args(args, label)
  end
  local function begin()
    if variant.remote then
      remote_backend.list(self.root, function(remotes, err)
        if not remotes or #remotes == 0 then
          notify(err or "This repository has no configured remote", vim.log.levels.WARN)
          return
        end
        local items = {}
        for _, remote in ipairs(remotes) do
          items[#items + 1] = {
            label = remote.name,
            detail = remote.fetch_url,
            action = function()
              start(variant.args(remote.name), variant.label:gsub("<remote>", remote.name))
            end,
          }
        end
        Menu.choose("Which remote?", items)
      end)
      return
    end
    start(variant.args, variant.label)
  end

  if variant.confirm then
    Menu.confirm(variant.confirm, "Run it", begin)
  else
    begin()
  end
end

local function remote_management_items(self)
  return {
    {
      label = "Add a remote…",
      action = function()
        Menu.ask("Remote name: ", nil, function(name)
          Menu.ask(("URL for %s: "):format(name), nil, function(url)
            remote_backend.add(self.root, name, url, settler(self))
          end)
        end)
      end,
    },
    {
      label = "Rename a remote…",
      action = function()
        remote_backend.list(self.root, function(remotes)
          local items = {}
          for _, remote in ipairs(remotes or {}) do
            items[#items + 1] = {
              label = remote.name,
              detail = remote.fetch_url,
              action = function()
                Menu.ask(("Rename %s to: "):format(remote.name), remote.name, function(name)
                  remote_backend.rename(self.root, remote.name, name, settler(self))
                end)
              end,
            }
          end
          Menu.choose("Rename which remote?", items)
        end)
      end,
    },
    {
      label = "Remove a remote…",
      action = function()
        remote_backend.list(self.root, function(remotes)
          local items = {}
          for _, remote in ipairs(remotes or {}) do
            items[#items + 1] = {
              label = remote.name,
              detail = remote.fetch_url,
              action = function()
                Menu.confirm(
                  ("Remove the remote %s and its tracking refs?"):format(remote.name),
                  "Remove",
                  function()
                    remote_backend.remove(self.root, remote.name, settler(self))
                  end
                )
              end,
            }
          end
          Menu.choose("Remove which remote?", items)
        end)
      end,
    },
  }
end

function M.remote_menu(self)
  local items = {}
  for _, group in ipairs({ "fetch", "pull", "push" }) do
    for _, variant in ipairs(remote_backend.variants[group]) do
      items[#items + 1] = {
        label = variant.label,
        action = function()
          run_variant(self, variant)
        end,
      }
    end
  end
  vim.list_extend(items, remote_management_items(self))
  Menu.choose("Remote", items)
end

-- Stashes ---------------------------------------------------------------------

function M.stash_menu(self)
  local entry = self:selected_entry()
  local items = {
    {
      label = "Stash everything",
      detail = "including untracked files",
      action = function()
        Menu.ask("Message (optional, <CR> to skip): ", nil, function(message)
          stash_backend.push(self.root, message, {}, settler(self))
        end)
      end,
    },
    {
      label = "Stash but keep the index",
      detail = "staged work stays staged",
      action = function()
        stash_backend.push(self.root, nil, { keep_index = true }, settler(self))
      end,
    },
    {
      label = "Stash the staged changes only",
      action = function()
        stash_backend.push(self.root, nil, { staged = true }, settler(self))
      end,
    },
  }

  if self.active_panel == "status" and not self.range then
    local entries = self:selected_entries()
    local paths = {}
    for _, item in ipairs(entries) do
      if item.file then
        paths[#paths + 1] = item.file.path
      end
    end
    if #paths > 0 then
      items[#items + 1] = {
        label = ("Stash %d selected file%s"):format(#paths, #paths == 1 and "" or "s"),
        action = function()
          stash_backend.push(self.root, nil, { paths = paths }, settler(self))
        end,
      }
    end
  end

  if entry and entry.kind == "stash" then
    local stash = entry.stash
    items[#items + 1] = {
      label = ("Apply %s and restore the index"):format(stash.ref),
      action = function()
        stash_backend.apply(self.root, stash, { index = true }, settler(self))
      end,
    }
    items[#items + 1] = {
      label = ("Pop %s and restore the index"):format(stash.ref),
      action = function()
        stash_backend.pop(self.root, stash, { index = true }, settler(self))
      end,
    }
    items[#items + 1] = {
      label = ("Branch from %s…"):format(stash.ref),
      detail = "for a stash that no longer applies",
      action = function()
        Menu.ask("New branch name: ", nil, function(name)
          stash_backend.branch(self.root, name, stash, settler(self))
        end)
      end,
    }
  end
  Menu.choose("Stash", items)
end

-- Commit options --------------------------------------------------------------

function M.commit_menu(self)
  local entry = self:selected_entry()
  local items = {
    {
      label = "Commit with --signoff",
      action = function()
        self:prompt_commit({ signoff = true })
      end,
    },
    {
      label = "Commit with --no-verify",
      detail = "skip the pre-commit hooks",
      action = function()
        self:prompt_commit({ no_verify = true })
      end,
    },
    {
      label = "Commit with --gpg-sign",
      action = function()
        self:prompt_commit({ gpg_sign = true })
      end,
    },
    {
      label = "Commit --allow-empty",
      action = function()
        self:prompt_commit({ allow_empty = true })
      end,
    },
    {
      label = "Amend without editing the message",
      detail = "git commit --amend --no-edit",
      action = function()
        mutate.commit(self.root, "", { amend = true, no_edit = true }, settler(self))
      end,
    },
    {
      label = "Reword HEAD",
      detail = "amend the message only",
      action = function()
        self:prompt_commit({ amend = true })
      end,
    },
  }

  if entry and entry.kind == "commit" then
    local oid = entry.commit.oid
    items[#items + 1] = {
      label = ("Commit as fixup! for %s"):format(short_oid(oid)),
      detail = "autosquash folds it in silently",
      action = function()
        mutate.commit(self.root, "", { fixup = oid }, settler(self))
      end,
    }
    items[#items + 1] = {
      label = ("Commit as squash! for %s"):format(short_oid(oid)),
      detail = "autosquash keeps both messages",
      action = function()
        mutate.commit(self.root, "", { squash = oid }, settler(self))
      end,
    }
  end
  Menu.choose("Commit", items)
end

-- File operations -------------------------------------------------------------

function M.file_menu(self)
  if self:review_only() then
    return
  end
  local entry = self:selected_entry()
  if not entry or not entry.file then
    notify("Select a file first", vim.log.levels.WARN)
    return
  end
  local path = entry.file.path
  local items = {}

  if entry.section == "untracked" then
    items[#items + 1] = {
      label = "Track as an empty file",
      detail = "git add --intent-to-add, so its lines become stageable",
      action = function()
        mutate.intent_to_add(self.root, path, settler(self))
      end,
    }
  else
    items[#items + 1] = {
      label = "Stop tracking, keep on disk",
      detail = "git rm --cached",
      action = function()
        Menu.confirm(("Stop tracking %s?"):format(path), "Stop tracking", function()
          mutate.untrack(self.root, path, settler(self))
        end)
      end,
    }
  end

  items[#items + 1] = {
    label = "Rename…",
    detail = "git mv, so the rename is staged as one",
    action = function()
      Menu.ask(("Rename %s to: "):format(path), path, function(target)
        mutate.move(self.root, path, target, settler(self))
      end)
    end,
  }
  items[#items + 1] = {
    label = "Restore from a commit…",
    detail = "overwrite the index and the worktree copy",
    action = function()
      Menu.ask(("Restore %s from: "):format(path), "HEAD", function(revision)
        Menu.confirm(
          ("Overwrite %s with its %s content?"):format(path, revision),
          "Restore",
          function()
            mutate.restore_from(self.root, revision, path, settler(self))
          end
        )
      end)
    end,
  }
  Menu.choose(path, items)
end

-- Copy ------------------------------------------------------------------------

local function copy(value, description)
  vim.fn.setreg("+", value)
  vim.fn.setreg('"', value)
  notify(("Copied %s"):format(description))
end

function M.copy_menu(self)
  local entry = self:selected_entry()
  local path = selected_path(self)
  local items = {}

  if entry and entry.kind == "commit" then
    local commit = entry.commit
    items[#items + 1] = {
      label = "Commit hash",
      detail = short_oid(commit.oid),
      action = function()
        copy(commit.oid, "the commit hash")
      end,
    }
    items[#items + 1] = {
      label = "Subject",
      detail = commit.subject,
      action = function()
        copy(commit.subject, "the subject")
      end,
    }
    items[#items + 1] = {
      label = "Full message",
      action = function()
        log_backend.message(self.root, commit.oid, function(message, err)
          if not message then
            notify(err or "Unable to read the message", vim.log.levels.ERROR)
            return
          end
          copy(message, "the message")
        end)
      end,
    }
    items[#items + 1] = {
      label = "Web link",
      detail = "from the remote URL",
      action = function()
        remote_backend.default_remote(self.root, function(remote, err)
          if not remote then
            notify(err or "No remote to build a link from", vim.log.levels.WARN)
            return
          end
          remote_backend.list(self.root, function(remotes)
            local url
            for _, item in ipairs(remotes or {}) do
              if item.name == remote then
                url = remote_backend.browse_url(item.fetch_url)
              end
            end
            if not url then
              notify("The remote URL is not one ngit can turn into a link", vim.log.levels.WARN)
              return
            end
            copy(("%s/commit/%s"):format(url, commit.oid), "the commit link")
          end)
        end)
      end,
    }
  end

  if entry and entry.kind == "branch" then
    items[#items + 1] = {
      label = "Ref name",
      detail = entry.branch.name,
      action = function()
        copy(entry.branch.name, "the ref name")
      end,
    }
    items[#items + 1] = {
      label = "Tip hash",
      detail = short_oid(entry.branch.oid),
      action = function()
        copy(entry.branch.oid, "the tip hash")
      end,
    }
  end

  if path then
    items[#items + 1] = {
      label = "Path, relative to the repository",
      detail = path,
      action = function()
        copy(path, "the path")
      end,
    }
    items[#items + 1] = {
      label = "Absolute path",
      action = function()
        copy(vim.fs.joinpath(self.root, path), "the absolute path")
      end,
    }
  end

  if self.current_diff and self.current_diff.text ~= "" then
    items[#items + 1] = {
      label = "The diff as a patch",
      action = function()
        copy(self.current_diff.text, "the patch")
      end,
    }
  end

  if #items == 0 then
    notify("There is nothing selected to copy", vim.log.levels.WARN)
    return
  end
  Menu.choose("Copy", items)
end

-- Review range ----------------------------------------------------------------

function M.set_range(self, spec)
  if not spec or spec == "" then
    self.range = nil
    self.range_files = nil
    self:refresh()
    return
  end
  range_backend.validate(self.root, spec, function(ok, err)
    if not ok then
      notify(err or ("%s is not a range git can resolve"):format(spec), vim.log.levels.ERROR)
      return
    end
    self.range = { spec = spec }
    self.panels.status.filter = nil
    self.panels.status.selected = 1
    self:focus_panel("status")
    self:refresh()
  end)
end

function M.review_upstream(self)
  range_backend.review_spec(self.root, function(spec, err)
    if not spec then
      notify(err or "Nothing to review against", vim.log.levels.WARN)
      return
    end
    M.set_range(self, spec)
  end)
end

function M.review(self)
  local entry = self:selected_entry()
  local items = {
    {
      label = "Review this branch",
      detail = "everything it adds over its upstream",
      action = function()
        M.review_upstream(self)
      end,
    },
  }

  if entry and entry.kind == "branch" and not entry.branch.current then
    items[#items + 1] = {
      label = ("Compare with %s"):format(entry.branch.name),
      detail = ("%s...HEAD"):format(entry.branch.name),
      action = function()
        M.set_range(self, entry.branch.name .. "...HEAD")
      end,
    }
  end
  if entry and entry.kind == "commit" then
    local oid = entry.commit.oid
    items[#items + 1] = {
      label = ("Compare with %s"):format(short_oid(oid)),
      detail = ("%s..HEAD"):format(short_oid(oid)),
      action = function()
        M.set_range(self, oid .. "..HEAD")
      end,
    }
  end

  items[#items + 1] = {
    label = "Compare with…",
    detail = "any range git understands",
    action = function()
      Menu.ask("Range: ", self.range and self.range.spec or "main...HEAD", function(spec)
        M.set_range(self, spec)
      end)
    end,
  }
  if self.range then
    items[#items + 1] = {
      label = "Back to the working tree",
      detail = ("leave %s"):format(self.range.spec),
      action = function()
        M.set_range(self, nil)
      end,
    }
  end
  Menu.choose("Review", items)
end

-- File history ----------------------------------------------------------------

function M.set_history(self, path)
  local panel = self.panels.commits
  self.history = path and { path = path, follow = true } or nil
  panel.filter = nil
  panel.selected = 1
  self:focus_panel("commits")
  self:refresh()
end

function M.file_history(self)
  local path = selected_path(self)
  local items = {}
  if path then
    items[#items + 1] = {
      label = ("Follow %s"):format(path),
      detail = "git log --follow",
      action = function()
        M.set_history(self, path)
      end,
    }
  end
  items[#items + 1] = {
    label = "Follow another path…",
    action = function()
      Menu.ask("Path: ", path, function(value)
        M.set_history(self, value)
      end)
    end,
  }
  if self.history then
    items[#items + 1] = {
      label = "Back to the whole history",
      detail = ("stop following %s"):format(self.history.path),
      action = function()
        M.set_history(self, nil)
      end,
    }
  end
  Menu.choose("History", items)
end

-- Blame -----------------------------------------------------------------------

function M.blame(self)
  local path = selected_path(self)
  if not path then
    notify("Select a file to blame", vim.log.levels.WARN)
    return
  end
  local _, line = self:preview_location()
  M.blame_path(self, path, line)
end

---@param path string repository-relative
---@param line integer? row to start on
function M.blame_path(self, path, line)
  blame_backend.load(
    self.root,
    path,
    { max_bytes = self.config.max_diff_bytes },
    function(lines, commits, err)
      if not lines then
        notify(err or ("Unable to blame %s"):format(path), vim.log.levels.ERROR)
        return
      end
      local Blame = require("ngit.ui.blame")
      self.blame_view = Blame.open({
        path = path,
        lines = lines,
        commits = commits,
        cursor = line,
        on_commit = function(oid)
          self:reveal_commit(oid)
        end,
      })
    end
  )
end

-- Worktrees and submodules ----------------------------------------------------

local function open_repository(path)
  require("ngit").open({ cwd = path })
end

function M.repos_menu(self)
  worktree_backend.list(self.root, function(worktrees, err)
    if not worktrees then
      notify(err or "Unable to list worktrees", vim.log.levels.ERROR)
      return
    end
    -- Git reports resolved paths while the session root may have reached the
    -- repository through a symlink, so both sides are resolved before the current
    -- worktree is filtered out of its own switch list.
    local here = vim.uv.fs_realpath(self.root) or self.root
    local items = {}
    for _, tree in ipairs(worktrees) do
      if (vim.uv.fs_realpath(tree.path) or tree.path) ~= here then
        items[#items + 1] = {
          label = tree.path,
          detail = tree.branch ~= "" and tree.branch or (tree.detached and "detached" or "bare"),
          action = function()
            open_repository(tree.path)
          end,
        }
      end
    end

    items[#items + 1] = {
      label = "Add a worktree…",
      action = function()
        Menu.ask("Worktree path: ", nil, function(path)
          Menu.ask("New branch name (<CR> to reuse the current): ", nil, function(branch)
            worktree_backend.add(self.root, path, branch, function(ok, add_err)
              self.after_mutation(self, ok, add_err)
              if ok then
                open_repository(path)
              end
            end)
          end)
        end)
      end,
    }
    if #worktrees > 1 then
      items[#items + 1] = {
        label = "Remove a worktree…",
        action = function()
          local removable = {}
          for _, tree in ipairs(worktrees) do
            if tree.path ~= self.root and not tree.bare then
              removable[#removable + 1] = {
                label = tree.path,
                action = function()
                  Menu.confirm(
                    ("Remove the worktree at %s?"):format(tree.path),
                    "Remove",
                    function()
                      worktree_backend.remove(self.root, tree.path, settler(self))
                    end
                  )
                end,
              }
            end
          end
          Menu.choose("Remove which worktree?", removable)
        end,
      }
    end

    submodule_backend.list(self.root, function(submodules)
      for _, submodule in ipairs(submodules or {}) do
        items[#items + 1] = {
          label = ("submodule %s"):format(submodule.path),
          detail = submodule.state,
          action = function()
            open_repository(vim.fs.joinpath(self.root, submodule.path))
          end,
        }
      end
      if submodules and #submodules > 0 then
        items[#items + 1] = {
          label = "Update every submodule",
          detail = "git submodule update --init --recursive",
          action = function()
            submodule_backend.update(self.root, settler(self))
          end,
        }
      end
      Menu.choose("Worktrees and submodules", items)
    end)
  end)
end

-- Diff options ----------------------------------------------------------------

--- Diff options live on the session's config copy rather than the global one, so
--- toggling them affects this view and not the next repository opened.
local function reload_previews(self)
  self.cache:clear()
  self.model_cache:clear()
  self:render_files()
  self:load_preview()
  self:update_actions()
end

function M.toggle_whitespace(self)
  self.config = vim.tbl_extend("force", self.config, {
    ignore_whitespace = not self.config.ignore_whitespace,
  })
  notify(
    self.config.ignore_whitespace and "Ignoring whitespace-only changes"
      or "Showing whitespace changes"
  )
  reload_previews(self)
end

local max_context = 64

function M.adjust_context(self, delta)
  local context = math.max(0, math.min(max_context, self.config.context + delta))
  if context == self.config.context then
    return
  end
  self.config = vim.tbl_extend("force", self.config, { context = context })
  notify(("%d context line%s"):format(context, context == 1 and "" or "s"))
  reload_previews(self)
end

-- Conflicts -------------------------------------------------------------------

--- Conflict blocks of the selected file, together with the preview rows they
--- start on, so navigation and per-block resolution agree on what "here" means.
local function conflict_rows(self)
  local entry = self:selected_entry()
  if not entry or entry.section ~= "conflict" then
    return nil, nil, "Select a conflicted file first"
  end
  local blocks, err = conflict_backend.blocks(self.root, entry.file.path)
  if not blocks then
    return nil, nil, err
  end
  if #blocks == 0 then
    return nil, nil, ("%s carries no conflict markers"):format(entry.file.path)
  end
  return entry, blocks, nil
end

function M.jump_conflict(self, direction)
  local entry, blocks, err = conflict_rows(self)
  if not entry then
    notify(err, vim.log.levels.WARN)
    return
  end
  local pane, window = self:preview_pane()
  if not pane or not window then
    return
  end
  -- The preview of a conflicted file is index-to-worktree, so its new-side line
  -- numbers are the worktree lines the markers sit on.
  local rows = {}
  for _, block in ipairs(blocks) do
    for row, number in pairs(pane.source_numbers) do
      if number == block.start then
        rows[#rows + 1] = row
      end
    end
  end
  if #rows == 0 then
    notify("The conflict markers are not visible in this preview", vim.log.levels.WARN)
    return
  end
  table.sort(rows)

  local current = vim.api.nvim_win_get_cursor(window)[1]
  local target
  if direction > 0 then
    for _, row in ipairs(rows) do
      if row > current then
        target = row
        break
      end
    end
    target = target or rows[1]
  else
    for index = #rows, 1, -1 do
      if rows[index] < current then
        target = rows[index]
        break
      end
    end
    target = target or rows[#rows]
  end
  pcall(vim.api.nvim_win_set_cursor, window, { target, 0 })
end

return M
