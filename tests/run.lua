local failures = {}
local passed = 0

local function fail(message)
  error(message, 2)
end

local function equal(expected, actual, message)
  if not vim.deep_equal(expected, actual) then
    fail(
      (message and (message .. "\n") or "")
        .. "expected: "
        .. vim.inspect(expected)
        .. "\nactual: "
        .. vim.inspect(actual)
    )
  end
end

local function truthy(value, message)
  if not value then
    fail(message or ("expected truthy value, got " .. vim.inspect(value)))
  end
end

local function test(name, callback)
  local ok, err = xpcall(callback, debug.traceback)
  if ok then
    passed = passed + 1
    io.stdout:write("ok - " .. name .. "\n")
  else
    failures[#failures + 1] = { name = name, error = err }
    io.stderr:write("not ok - " .. name .. "\n" .. err .. "\n")
  end
end

local function write_file(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
end

local function read_file(path)
  local file = assert(io.open(path, "rb"))
  local content = file:read("*a")
  file:close()
  return content
end

local function git(root, args, opts)
  opts = opts or {}
  -- init.defaultBranch is unset on a stock machine, where git falls back to
  -- "master". A bare repository created that way points HEAD at a branch the
  -- tests never push, so cloning it checks out nothing at all and the failure
  -- surfaces later as an unrelated "nothing to commit". Pin it here so no test
  -- depends on whoever's machine is running it.
  local command = {
    "git",
    "-c",
    "init.defaultBranch=main",
    "-c",
    "user.name=ngit tests",
    "-c",
    "user.email=ngit@example.test",
  }
  vim.list_extend(command, args)
  local result = vim
    .system(command, {
      cwd = root,
      text = true,
      stdin = opts.stdin,
    })
    :wait(10000)
  if not opts.accept or not opts.accept[result.code] then
    equal(0, result.code, table.concat(command, " ") .. "\n" .. (result.stderr or ""))
  end
  return result
end

local function repository()
  local root = vim.fn.tempname()
  assert(vim.uv.fs_mkdir(root, 448))
  git(root, { "init", "-q", "-b", "main" })
  git(root, { "config", "user.name", "ngit tests" })
  git(root, { "config", "user.email", "ngit@example.test" })
  return root
end

local function wait_for(register)
  local complete = false
  local values
  register(function(...)
    values = { ... }
    complete = true
  end)
  truthy(
    vim.wait(10000, function()
      return complete
    end, 10),
    "asynchronous operation timed out"
  )
  return unpack(values)
end

test("plugin registers every public entrypoint command", function()
  local commands = vim.api.nvim_get_commands({})
  truthy(commands.NGit)
  truthy(commands.NGitLog)
  truthy(commands.NGitBranches)
  truthy(commands.NGitStashes)
  truthy(commands.NGitRefresh)
  truthy(commands.NGitClose)
end)

test("porcelain v2 parser handles headers and every entry class", function()
  local parse = require("ngit.git.status").parse
  local data = table.concat({
    "# branch.oid abc123",
    "# branch.head main",
    "# branch.upstream origin/main",
    "# branch.ab +2 -3",
    "# stash 4",
    "1 M. N... 100644 100644 100644 abc def staged.lua",
    "1 .M N... 100644 100644 100644 abc def worktree.lua",
    "2 R. N... 100644 100644 100644 abc def R100 new name.lua",
    "old name.lua",
    "u UU N... 100644 100644 100644 100644 abc def ghi conflict.lua",
    "? untracked file.lua",
    "",
  }, "\0")
  local status = parse(data)

  equal("main", status.branch)
  equal("origin/main", status.upstream)
  equal(2, status.ahead)
  equal(3, status.behind)
  equal(4, status.stash_count)
  equal(5, #status.files)
  local by_path = {}
  for _, file in ipairs(status.files) do
    by_path[file.path] = file
  end
  equal("old name.lua", by_path["new name.lua"].old_path)
  equal("conflict", by_path["conflict.lua"].kind)
  equal("untracked", by_path["untracked file.lua"].kind)
end)

test("diff parser locates hunks and extracts only the selected hunk", function()
  local diff = require("ngit.git.diff")
  local patch = table.concat({
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1 +1 @@",
    "-one",
    "+ONE",
    "@@ -10 +10 @@",
    "-ten",
    "+TEN",
    "",
  }, "\n")
  local parsed = diff.parse(patch, 10000)
  equal({ 4, 7 }, parsed.hunks)
  local selected = assert(diff.patch_at_hunk(parsed.lines, 8))
  truthy(selected:find("@@ %-10 %+10 @@", 1, false))
  truthy(not selected:find("%-one"))
end)

test("diff parser marks an externally truncated stream", function()
  local parsed = require("ngit.git.diff").parse("diff --git a/a b/a\n@@ -1 +1 @@\n-old", 100, true)
  equal(true, parsed.truncated)
  truthy(parsed.text:find("preview truncated", 1, true))
end)

test("semantic diff model aligns old and new rows without raw plumbing", function()
  local patch = table.concat({
    "commit abcdef",
    "Author: Test User",
    "",
    "diff --git a/example.lua b/example.lua",
    "index 1111111..2222222 100644",
    "--- a/example.lua",
    "+++ b/example.lua",
    "@@ -1,3 +1,4 @@ local value",
    " local before = true",
    "-local value = 'old'",
    "+local value = 'new'",
    "+local added = true",
    " return value",
    "",
  }, "\n")
  local parsed = require("ngit.git.diff").parse(patch, 10000)
  equal(1, #parsed.files)
  equal("example.lua", parsed.files[1].display_path)
  equal(1, #parsed.files[1].hunks)
  equal("change", parsed.files[1].hunks[1].rows[2].left.kind)
  equal("change", parsed.files[1].hunks[1].rows[2].right.kind)
  equal(nil, parsed.files[1].hunks[1].rows[3].left)
  equal("add", parsed.files[1].hunks[1].rows[3].right.kind)

  local split = require("ngit.ui.diff_view").split(parsed, { title = "example.lua" })
  equal(#split.left.lines, #split.right.lines)
  truthy(table.concat(split.left.lines, "\n"):find("local value = 'old'", 1, true))
  truthy(table.concat(split.right.lines, "\n"):find("local value = 'new'", 1, true))
  truthy(not table.concat(split.left.lines, "\n"):find("diff --git", 1, true))
  -- The commit preamble leads the body, so hunk rows are located by content.
  truthy(table.concat(split.left.lines, "\n"):find("Author: Test User", 1, true))
  local hunk_row
  for row, line in ipairs(split.left.lines) do
    if line:find("local value = 'old'", 1, true) then
      hunk_row = row
    end
  end
  truthy(hunk_row)
  truthy(split.left.row_hunks[hunk_row])
  equal(1, #split.hunks)
  local groups = {}
  for _, item in ipairs(split.left.highlights) do
    groups[item.group] = true
  end
  truthy(groups.NgitDiffDelete)
  truthy(groups.NgitDiffDeleteText)
  local right_groups = {}
  for _, item in ipairs(split.right.highlights) do
    right_groups[item.group] = true
  end
  truthy(right_groups.NgitDiffAdd)
  truthy(right_groups.NgitDiffAddText)
  local unified = require("ngit.ui.diff_view").unified(parsed, { title = "example.lua" }, split)
  local unified_groups = {}
  for _, item in ipairs(unified.unified.highlights) do
    unified_groups[item.group] = true
  end
  truthy(unified_groups.NgitDiffDelete)
  truthy(unified_groups.NgitDiffAdd)
  truthy(unified_groups.NgitDiffDeleteText)
  truthy(unified_groups.NgitDiffAddText)
end)

test("semantic diff model decodes quoted rename-only paths", function()
  local patch = table.concat({
    [[diff --git "a/old\tname.lua" "b/new\tname.lua"]],
    "similarity index 100%",
    [[rename from "old\tname.lua"]],
    [[rename to "new\tname.lua"]],
    "",
  }, "\n")
  local parsed = require("ngit.git.diff").parse(patch, 10000)
  equal(1, #parsed.files)
  equal("old\tname.lua", parsed.files[1].old_path)
  equal("new\tname.lua", parsed.files[1].new_path)
  equal("new\tname.lua", parsed.files[1].display_path)
end)

test("semantic diff model decodes quoted binary paths", function()
  local patch = table.concat({
    [[diff --git "a/assets/old image.png" "b/assets/new image.png"]],
    [[Binary files "a/assets/old image.png" and "b/assets/new image.png" differ]],
    "",
  }, "\n")
  local parsed = require("ngit.git.diff").parse(patch, 10000)
  equal(1, #parsed.files)
  equal(true, parsed.files[1].binary)
  equal("assets/old image.png", parsed.files[1].old_path)
  equal("assets/new image.png", parsed.files[1].new_path)
end)

test("intraline highlighting uses valid UTF-8 byte boundaries", function()
  local patch = table.concat({
    "diff --git a/example.lua b/example.lua",
    "--- a/example.lua",
    "+++ b/example.lua",
    "@@ -1 +1 @@",
    "-local café = 1",
    "+local café = 2",
    "",
  }, "\n")
  local parsed = require("ngit.git.diff").parse(patch, 10000)
  local model = require("ngit.ui.diff_view").split(parsed, { title = "UTF-8" })
  local spans = {}
  for _, item in ipairs(model.left.highlights) do
    if item.group == "NgitDiffDeleteText" then
      spans[#spans + 1] = item
    end
  end
  equal(1, #spans)
  equal("1", model.left.lines[spans[1].row + 1]:sub(spans[1].col + 1, spans[1].end_col))
end)

test("configuration rejects misspelled options", function()
  local ok, err = pcall(require("ngit").setup, { debounce_milliseconds = 10 })
  equal(false, ok)
  truthy(tostring(err):find("unknown configuration option", 1, true))
  require("ngit").setup()
end)

test("configuration rejects unsafe resource limits", function()
  local ok, err = pcall(require("ngit").setup, { cache_entries = 0 })
  equal(false, ok)
  truthy(tostring(err):find("positive integer", 1, true))
  require("ngit").setup()
end)

test("configuration validates the preview cache byte budget", function()
  local ok, err = pcall(require("ngit").setup, { max_cache_bytes = 100 })
  equal(false, ok)
  truthy(tostring(err):find("max_cache_bytes", 1, true))
  require("ngit").setup()
end)

test("diff highlights provide visible theme-derived backgrounds", function()
  local highlights = require("ngit.ui.highlights")
  highlights.setup()
  local add = vim.api.nvim_get_hl(0, { name = "NgitDiffAdd", link = false })
  local delete = vim.api.nvim_get_hl(0, { name = "NgitDiffDelete", link = false })
  local add_text = vim.api.nvim_get_hl(0, { name = "NgitDiffAddText", link = false })
  local delete_text = vim.api.nvim_get_hl(0, { name = "NgitDiffDeleteText", link = false })
  truthy(add.bg)
  truthy(delete.bg)
  truthy(add_text.bg)
  truthy(delete_text.bg)
  truthy(add.bg ~= delete.bg)
  truthy(add_text.bg ~= add.bg)
  truthy(delete_text.bg ~= delete.bg)
  for _, name in ipairs({
    "NgitStagedSign",
    "NgitUnstagedSign",
    "NgitUntrackedSign",
    "NgitConflictSign",
  }) do
    equal(nil, vim.api.nvim_get_hl(0, { name = name, link = false }).bg)
  end

  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local changed_background = normal.bg == 0xfefefe and 0x010101 or 0xfefefe
  vim.api.nvim_set_hl(0, "Normal", vim.tbl_extend("force", normal, { bg = changed_background }))
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  local recolored = vim.api.nvim_get_hl(0, { name = "NgitDiffAdd", link = false })
  truthy(recolored.bg ~= add.bg)

  vim.api.nvim_set_hl(0, "NgitDiffAdd", { bg = 0x123456 })
  vim.api.nvim_set_hl(0, "Normal", normal)
  vim.api.nvim_exec_autocmds("ColorScheme", {})
  equal(0x123456, vim.api.nvim_get_hl(0, { name = "NgitDiffAdd", link = false }).bg)
  vim.api.nvim_set_hl(0, "NgitDiffAdd", recolored)
end)

test("dashboard is the default layout with configurable panel navigation", function()
  local defaults = require("ngit.config").defaults()
  equal("dashboard", defaults.layout)
  equal("<Tab>", defaults.mappings.next_panel)
  equal("<S-Tab>", defaults.mappings.prev_panel)
  equal("1", defaults.mappings.focus_status)
  equal("4", defaults.mappings.focus_stashes)
  equal("0", defaults.mappings.focus_preview)
  equal("auto", defaults.diff_layout)
  equal(true, defaults.hide_statusline)
  equal("dv", defaults.mappings.toggle_diff)
  equal("dashboard", require("ngit").setup({ layout = "vertical" }).layout)
  require("ngit").setup()
end)

test("contextual actions use configured keys and exclude unrelated panels", function()
  local mappings = require("ngit.config").defaults().mappings
  mappings.stage = "S"
  local available = require("ngit.ui.actions").for_context({
    panel = "status",
    entry = {
      section = "unstaged",
      file = { kind = "modified" },
    },
  }, mappings)
  local by_id = {}
  for _, item in ipairs(available) do
    by_id[item.id] = item
  end
  equal("S", by_id.stage.key)
  equal(nil, by_id.unstage)
  equal(nil, by_id.primary)

  mappings.stage = false
  available = require("ngit.ui.actions").for_context({
    panel = "status",
    entry = {
      section = "unstaged",
      file = { kind = "modified" },
    },
  }, mappings)
  for _, item in ipairs(available) do
    truthy(item.id ~= "stage", "disabled actions must not appear")
  end
end)

test("LRU evicts the least recently used value", function()
  local cache = require("ngit.util.lru").new(2)
  cache:set("a", 1)
  cache:set("b", 2)
  equal(1, cache:get("a"))
  cache:set("c", 3)
  equal(nil, cache:get("b"))
  equal(1, cache:get("a"))
  equal(3, cache:get("c"))
end)

test("LRU also evicts by total value weight", function()
  local cache = require("ngit.util.lru").new(10, {
    max_weight = 5,
    weigh = function(value)
      return #value
    end,
  })
  equal(true, cache:set("a", "123"))
  equal(true, cache:set("b", "45"))
  equal(5, cache.total_weight)
  cache:get("a")
  equal(true, cache:set("c", "x"))
  equal(nil, cache:get("b"))
  equal("123", cache:get("a"))
  equal("x", cache:get("c"))
  equal(false, cache:set("huge", "123456"))
  equal(nil, cache:get("huge"))
  truthy(cache.total_weight <= cache.max_weight)
end)

test("commit, branch, and stash backends parse a real repository", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "history.txt"), "first\n")
  git(root, { "add", "history.txt" })
  git(root, { "commit", "-q", "-m", "first commit" })
  write_file(vim.fs.joinpath(root, "history.txt"), "second\n")
  git(root, { "commit", "-q", "-am", "second commit" })

  local commits, has_more, log_err = wait_for(function(done)
    require("ngit.git.log").list(root, { limit = 1 }, done)
  end)
  equal(nil, log_err)
  equal(1, #commits)
  equal(true, has_more)
  equal("second commit", commits[1].subject)
  equal(40, #commits[1].oid)

  local shown, show_err = wait_for(function(done)
    require("ngit.git.log").show(root, commits[1].oid, 10000, done)
  end)
  equal(nil, show_err)
  truthy(shown.text:find("second commit", 1, true))
  truthy(shown.text:find("+second", 1, true))

  local created, create_err = wait_for(function(done)
    require("ngit.git.branch").create(root, "feature/test", done)
  end)
  equal(true, created)
  equal(nil, create_err)
  local branches, branch_err = wait_for(function(done)
    require("ngit.git.branch").list(root, done)
  end)
  equal(nil, branch_err)
  local found_branch
  for _, branch in ipairs(branches) do
    if branch.name == "feature/test" then
      found_branch = branch
    end
  end
  truthy(found_branch)
  equal(true, found_branch.current)

  local main_branch
  for _, branch in ipairs(branches) do
    if branch.name == "main" then
      main_branch = branch
    end
  end
  local switched, switch_err = wait_for(function(done)
    require("ngit.git.branch").switch(root, main_branch, done)
  end)
  equal(true, switched)
  equal(nil, switch_err)
  local deleted, delete_err = wait_for(function(done)
    require("ngit.git.branch").delete(root, "feature/test", false, done)
  end)
  equal(true, deleted)
  equal(nil, delete_err)

  write_file(vim.fs.joinpath(root, "history.txt"), "stashed\n")
  local pushed, push_err = wait_for(function(done)
    require("ngit.git.stash").push(root, "test stash", done)
  end)
  equal(true, pushed)
  equal(nil, push_err)
  local stashes, stash_err = wait_for(function(done)
    require("ngit.git.stash").list(root, done)
  end)
  equal(nil, stash_err)
  equal(1, #stashes)
  truthy(stashes[1].subject:find("test stash", 1, true))
  local stash_diff = wait_for(function(done)
    require("ngit.git.stash").show(root, stashes[1], 10000, done)
  end)
  truthy(stash_diff.text:find("+stashed", 1, true))
  local applied, apply_err = wait_for(function(done)
    require("ngit.git.stash").apply(root, stashes[1], done)
  end)
  equal(true, applied)
  equal(nil, apply_err)
  truthy(git(root, { "diff" }).stdout:find("+stashed", 1, true))
  git(root, { "restore", "history.txt" })
  local dropped, drop_err = wait_for(function(done)
    require("ngit.git.stash").drop(root, stashes[1], done)
  end)
  equal(true, dropped)
  equal(nil, drop_err)

  write_file(vim.fs.joinpath(root, "history.txt"), "pop this\n")
  local repushed = wait_for(function(done)
    require("ngit.git.stash").push(root, "pop stash", done)
  end)
  equal(true, repushed)
  local pop_stashes = wait_for(function(done)
    require("ngit.git.stash").list(root, done)
  end)
  local popped, pop_err = wait_for(function(done)
    require("ngit.git.stash").pop(root, pop_stashes[1], done)
  end)
  equal(true, popped)
  equal(nil, pop_err)
  equal("pop this\n", read_file(vim.fs.joinpath(root, "history.txt")))
end)

test("commit history is empty rather than erroneous on an unborn branch", function()
  local root = repository()
  local commits, has_more, err = wait_for(function(done)
    require("ngit.git.log").list(root, { limit = 10 }, done)
  end)
  equal(nil, err)
  equal({}, commits)
  equal(false, has_more)
end)

test("commit backend creates and amends commits through stdin safely", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "commit.txt"), "one\n")
  git(root, { "add", "commit.txt" })

  local committed, commit_err = wait_for(function(done)
    require("ngit.git.mutate").commit(root, "created by ngit", false, done)
  end)
  equal(true, committed)
  equal(nil, commit_err)
  equal("created by ngit\n", git(root, { "log", "-1", "--format=%s" }).stdout)

  write_file(vim.fs.joinpath(root, "commit.txt"), "two\n")
  git(root, { "add", "commit.txt" })
  local amended, amend_err = wait_for(function(done)
    require("ngit.git.mutate").commit(root, "", true, done)
  end)
  equal(true, amended)
  equal(nil, amend_err)
  equal("created by ngit\n", git(root, { "log", "-1", "--format=%s" }).stdout)
  equal("two\n", git(root, { "show", "HEAD:commit.txt" }).stdout)
  local message, message_err = wait_for(function(done)
    require("ngit.git.log").head_message(root, done)
  end)
  equal(nil, message_err)
  equal("created by ngit", message)
end)

test("commit editor submits a multiline gitcommit buffer", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "editor.txt"), "content\n")
  git(root, { "add", "editor.txt" })

  local completed = false
  local editor = require("ngit.ui.commit_editor").new(root, {
    amend = false,
    on_complete = function()
      completed = true
    end,
  })
  vim.api.nvim_buf_set_lines(editor.buffer, 0, -1, false, {
    "subject from editor",
    "",
    "body from editor",
  })
  editor:submit()
  truthy(vim.wait(10000, function()
    return completed
  end, 10))
  equal(
    "subject from editor\n\nbody from editor\n\n",
    git(root, { "log", "-1", "--format=%B" }).stdout
  )
end)

test("streaming console appends output and cleans up its window", function()
  local console = require("ngit.ui.console").new("test operation")
  console:append("fir")
  console:append("st\nsecond")
  console:append("\n")
  console:append("third\r")
  console:append("\nfourth\r")
  console:append(" line\n")
  console:finish(true, 0)
  local lines = vim.api.nvim_buf_get_lines(console.buffer, 0, -1, false)
  local contents = table.concat(lines, "\n")
  truthy(contents:find("first", 1, true))
  truthy(not vim.tbl_contains(lines, "fir"))
  truthy(not vim.tbl_contains(lines, "st"))
  truthy(vim.tbl_contains(lines, "third"))
  truthy(vim.tbl_contains(lines, "fourth"))
  truthy(vim.tbl_contains(lines, " line"))
  truthy(contents:find("Completed successfully.", 1, true))
  local window = console.window
  console:close()
  equal(false, vim.api.nvim_win_is_valid(window))
end)

test("streaming console keeps bounded output without repeated front removal", function()
  local console = require("ngit.ui.console").new("bounded operation")
  console.max_lines = 3
  console:append("one\ntwo\nthree\nfour\n")
  console:finish(true, 0)
  local lines = vim.api.nvim_buf_get_lines(console.buffer, 0, -1, false)
  equal({ "four", "", "Completed successfully." }, lines)
  equal(3, console.line_count)
  console:close()
end)

test("remote backend streams local fetch, pull, and push operations", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "remote.txt"), "one\n")
  git(root, { "add", "remote.txt" })
  git(root, { "commit", "-q", "-m", "initial" })

  local bare = vim.fn.tempname()
  assert(vim.uv.fs_mkdir(bare, 448))
  git(bare, { "init", "-q", "--bare" })
  git(root, { "remote", "add", "origin", bare })
  git(root, { "push", "-q", "-u", "origin", "main" })

  write_file(vim.fs.joinpath(root, "remote.txt"), "pushed\n")
  git(root, { "commit", "-q", "-am", "push from ngit" })
  local chunks = {}
  local pushed, push_result = wait_for(function(done)
    require("ngit.git.remote").run(root, "push", function(stream, data)
      chunks[#chunks + 1] = stream .. ":" .. data
    end, done)
  end)
  equal(true, pushed)
  equal(0, push_result.code)
  truthy(#chunks > 0)

  local clone_parent = vim.fn.tempname()
  assert(vim.uv.fs_mkdir(clone_parent, 448))
  local clone = vim.fs.joinpath(clone_parent, "clone")
  git(clone_parent, { "clone", "-q", bare, clone })
  write_file(vim.fs.joinpath(clone, "remote.txt"), "pulled\n")
  git(clone, { "commit", "-q", "-am", "upstream change" })
  git(clone, { "push", "-q" })

  local fetched = wait_for(function(done)
    require("ngit.git.remote").run(root, "fetch", function() end, done)
  end)
  equal(true, fetched)
  local pulled, pull_result = wait_for(function(done)
    require("ngit.git.remote").run(root, "pull", function() end, done)
  end)
  equal(true, pulled)
  equal(0, pull_result.code)
  equal("pulled\n", git(root, { "show", "HEAD:remote.txt" }).stdout)
end)

test("conflicts can choose a side and continue an active merge", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "conflict.txt"), "base\n")
  git(root, { "add", "conflict.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  git(root, { "switch", "-q", "-c", "feature" })
  write_file(vim.fs.joinpath(root, "conflict.txt"), "feature\n")
  git(root, { "commit", "-q", "-am", "feature" })
  git(root, { "switch", "-q", "main" })
  write_file(vim.fs.joinpath(root, "conflict.txt"), "main\n")
  git(root, { "commit", "-q", "-am", "main" })
  local merge_ok = wait_for(function(done)
    require("ngit.git.sequencer").start(root, "merge", "feature", done)
  end)
  equal(false, merge_ok)

  local operation, detect_err = wait_for(function(done)
    require("ngit.git.sequencer").detect(root, done)
  end)
  equal("merge", operation)
  equal(nil, detect_err)
  local status = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal("conflict", status.files[1].kind)

  local resolved, resolve_err = wait_for(function(done)
    require("ngit.git.conflict").choose(root, "conflict.txt", "ours", done)
  end)
  equal(true, resolved)
  equal(nil, resolve_err)
  equal("main\n", read_file(vim.fs.joinpath(root, "conflict.txt")))

  local continued, continue_err = wait_for(function(done)
    require("ngit.git.sequencer").run(root, "merge", "continue", done)
  end)
  equal(true, continued)
  equal(nil, continue_err)
  local after = wait_for(function(done)
    require("ngit.git.sequencer").detect(root, done)
  end)
  equal(nil, after)
  truthy(git(root, { "log", "-1", "--format=%P" }).stdout:find(" ", 1, true))
end)

test("a selected commit can start a successful cherry-pick", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "base.txt"), "base\n")
  git(root, { "add", "base.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  git(root, { "switch", "-q", "-c", "topic" })
  write_file(vim.fs.joinpath(root, "picked.txt"), "picked\n")
  git(root, { "add", "picked.txt" })
  git(root, { "commit", "-q", "-m", "pick me" })
  local oid = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)
  git(root, { "switch", "-q", "main" })

  local picked, pick_err = wait_for(function(done)
    require("ngit.git.sequencer").start(root, "cherry-pick", oid, done)
  end)
  equal(true, picked)
  equal(nil, pick_err)
  equal("picked\n", read_file(vim.fs.joinpath(root, "picked.txt")))
  equal("pick me\n", git(root, { "log", "-1", "--format=%s" }).stdout)
end)

test("rebase can start successfully and an active merge can abort", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "base.txt"), "base\n")
  git(root, { "add", "base.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  git(root, { "switch", "-q", "-c", "topic" })
  write_file(vim.fs.joinpath(root, "topic.txt"), "topic\n")
  git(root, { "add", "topic.txt" })
  git(root, { "commit", "-q", "-m", "topic" })
  git(root, { "switch", "-q", "main" })
  write_file(vim.fs.joinpath(root, "main.txt"), "main\n")
  git(root, { "add", "main.txt" })
  git(root, { "commit", "-q", "-m", "main" })
  local main_oid = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)
  git(root, { "switch", "-q", "topic" })

  local rebased, rebase_err = wait_for(function(done)
    require("ngit.git.sequencer").start(root, "rebase", main_oid, done)
  end)
  equal(true, rebased)
  equal(nil, rebase_err)
  equal(main_oid .. "\n", git(root, { "merge-base", "HEAD", "main" }).stdout)

  git(root, { "switch", "-q", "main" })
  write_file(vim.fs.joinpath(root, "base.txt"), "main version\n")
  git(root, { "commit", "-q", "-am", "main conflict" })
  git(root, { "switch", "-q", "topic" })
  write_file(vim.fs.joinpath(root, "base.txt"), "topic version\n")
  git(root, { "commit", "-q", "-am", "topic conflict" })
  local before_merge = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)
  local merge_started = wait_for(function(done)
    require("ngit.git.sequencer").start(root, "merge", "main", done)
  end)
  equal(false, merge_started)
  local active = wait_for(function(done)
    require("ngit.git.sequencer").detect(root, done)
  end)
  equal("merge", active)
  local aborted, abort_err = wait_for(function(done)
    require("ngit.git.sequencer").run(root, "merge", "abort", done)
  end)
  equal(true, aborted)
  equal(nil, abort_err)
  equal(before_merge .. "\n", git(root, { "rev-parse", "HEAD" }).stdout)
end)

test("real repository status, diff, file stage and unstage round trip", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "tracked.txt"), "one\ntwo\nthree\n")
  git(root, { "add", "tracked.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "tracked.txt"), "one\nTWO\nthree\n")

  local status, status_err = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(nil, status_err)
  equal("main", status.branch)
  equal(1, #status.files)
  equal("M", status.files[1].worktree_status)

  local diff, diff_err = wait_for(function(done)
    require("ngit.git.diff").load(root, "unstaged", "tracked.txt", 3, 10000, done)
  end)
  equal(nil, diff_err)
  truthy(diff.text:find("+TWO", 1, true))

  local staged, stage_err = wait_for(function(done)
    require("ngit.git.mutate").stage_file(root, "tracked.txt", done)
  end)
  equal(true, staged)
  equal(nil, stage_err)

  local staged_diff = wait_for(function(done)
    require("ngit.git.diff").load(root, "staged", "tracked.txt", 3, 10000, done)
  end)
  local unstaged, unstage_err = wait_for(function(done)
    require("ngit.git.mutate").apply_cached(root, staged_diff.text, true, done)
  end)
  equal(true, unstaged)
  equal(nil, unstage_err)
  local porcelain = git(root, { "status", "--porcelain" }).stdout
  truthy(porcelain:find(" M tracked.txt", 1, true))
end)

test("a selected hunk can be staged without staging a distant hunk", function()
  local root = repository()
  local original = {}
  for index = 1, 30 do
    original[index] = ("line %02d"):format(index)
  end
  write_file(vim.fs.joinpath(root, "hunks.txt"), table.concat(original, "\n") .. "\n")
  git(root, { "add", "hunks.txt" })
  git(root, { "commit", "-q", "-m", "initial" })

  local changed = vim.deepcopy(original)
  changed[2] = "changed near start"
  changed[29] = "changed near end"
  write_file(vim.fs.joinpath(root, "hunks.txt"), table.concat(changed, "\n") .. "\n")

  local diff = wait_for(function(done)
    require("ngit.git.diff").load(root, "unstaged", "hunks.txt", 3, 10000, done)
  end)
  equal(2, #diff.hunks)
  local patch = assert(require("ngit.git.diff").patch_at_hunk(diff.lines, diff.hunks[1]))
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").apply_cached(root, patch, false, done)
  end)
  equal(true, ok)
  equal(nil, err)

  local cached = git(root, { "diff", "--cached", "--", "hunks.txt" }).stdout
  local worktree = git(root, { "diff", "--", "hunks.txt" }).stdout
  truthy(cached:find("changed near start", 1, true))
  truthy(not cached:find("changed near end", 1, true))
  truthy(worktree:find("changed near end", 1, true))
end)

test("rename and unusual filenames survive status parsing and literal staging", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "old name.txt"), "old\n")
  git(root, { "add", "old name.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  assert(
    vim.uv.fs_rename(vim.fs.joinpath(root, "old name.txt"), vim.fs.joinpath(root, "new name.txt"))
  )
  git(root, { "add", "-A" })

  local renamed = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(1, #renamed.files)
  equal("renamed", renamed.files[1].kind)
  equal("old name.txt", renamed.files[1].old_path)
  equal("new name.txt", renamed.files[1].path)

  local unusual = "literal :(top)\nname.txt"
  write_file(vim.fs.joinpath(root, unusual), "unusual\n")
  local before = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  local found = false
  for _, file in ipairs(before.files) do
    found = found or file.path == unusual
  end
  truthy(found, "unusual path was not parsed exactly")

  local staged, err = wait_for(function(done)
    require("ngit.git.mutate").stage_file(root, unusual, done)
  end)
  equal(true, staged)
  equal(nil, err)
end)

test("a newly added file can be fully unstaged by reversing its patch", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "new.txt"), "new content\n")
  git(root, { "add", "new.txt" })

  local diff = wait_for(function(done)
    require("ngit.git.diff").load(root, "staged", "new.txt", 3, 10000, done)
  end)
  truthy(diff.text:find("new file mode", 1, true))
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").apply_cached(root, diff.text, true, done)
  end)
  equal(true, ok)
  equal(nil, err)
  equal("?? new.txt\n", git(root, { "status", "--porcelain" }).stdout)
end)

test("whole-file unstage does not construct an unbounded patch", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "bounded.txt"), "bounded\n")
  git(root, { "add", "bounded.txt" })

  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").unstage_file(root, "bounded.txt", done)
  end)
  equal(true, ok)
  equal(nil, err)
  equal("?? bounded.txt\n", git(root, { "status", "--porcelain" }).stdout)
end)

test("a hunk can be staged from the structured new-side preview", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "preview.lua"), "local one = 1\nlocal two = 2\n")
  git(root, { "add", "preview.lua" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "preview.lua"), "local one = 1\nlocal two = 22\n")

  require("ngit").setup({ diff_layout = "side_by_side" })
  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.current_diff_models and session.current_diff
  end, 10))
  local session = require("ngit")._active_session()
  session.dashboard:focus_preview("right")
  local row
  for visible_row in pairs(session.current_diff_models.split.right.row_hunks) do
    row = row and math.min(row, visible_row) or visible_row
  end
  truthy(row)
  vim.api.nvim_win_set_cursor(session.dashboard.preview.right.window, { row, 0 })
  session:stage()
  truthy(
    vim.wait(10000, function()
      return git(root, { "diff", "--cached", "--", "preview.lua" }).stdout:find(
        "local two = 22",
        1,
        true
      ) ~= nil
    end, 10),
    "preview hunk was not staged"
  )
  require("ngit").close()
  require("ngit").setup()
end)

test("hunk extraction uses the enclosing file header in a multi-file diff", function()
  local diff = require("ngit.git.diff")
  local lines = {
    "commit abcdef",
    "Author: someone <someone@example.test>",
    "",
    "    subject line",
    "",
    "diff --git a/one b/one",
    "--- a/one",
    "+++ b/one",
    "@@ -1 +1 @@",
    "-one",
    "+ONE",
    "diff --git a/two b/two",
    "--- a/two",
    "+++ b/two",
    "@@ -5 +5 @@",
    "-two",
    "+TWO",
  }
  local second = assert(diff.patch_at_hunk(lines, 15))
  truthy(second:find("a/two b/two", 1, true), "second hunk lost its own header")
  truthy(not second:find("a/one b/one", 1, true), "second hunk borrowed the first file's header")
  truthy(not second:find("Author:", 1, true), "commit preamble leaked into the patch")

  local first = assert(diff.patch_at_hunk(lines, 9))
  truthy(first:find("a/one b/one", 1, true))
  truthy(not first:find("+TWO", 1, true))
end)

test("a line selection narrows a hunk the way git add -p splits one", function()
  local diff = require("ngit.git.diff")
  local lines = {
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1,4 +1,4 @@",
    " keep",
    "-old one",
    "+new one",
    "-old two",
    "+new two",
    " tail",
  }
  local function body(patch)
    return vim.split((patch:gsub("\n$", "")), "\n", { plain = true })
  end

  -- Staging: the target holds the old side, so an unselected removal has to stay
  -- as context and an unselected addition must not appear at all.
  equal({
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1,4 +1,4 @@",
    " keep",
    " old one",
    "-old two",
    "+new two",
    " tail",
  }, body(assert(diff.patch_for_rows(lines, { [8] = true, [9] = true }, {}))))

  -- Unstaging the same rows: the target holds the new side, so the two swap.
  equal({
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1,4 +1,4 @@",
    " keep",
    " new one",
    "-old two",
    "+new two",
    " tail",
  }, body(assert(diff.patch_for_rows(lines, { [8] = true, [9] = true }, { reverse = true }))))

  equal(nil, diff.patch_for_rows(lines, {}, {}))
end)

test("a line selection spanning two files keeps one header for each", function()
  local diff = require("ngit.git.diff")
  local lines = {
    "diff --git a/one b/one",
    "--- a/one",
    "+++ b/one",
    "@@ -1 +1 @@",
    "-one",
    "+ONE",
    "diff --git a/two b/two",
    "--- a/two",
    "+++ b/two",
    "@@ -1 +1 @@",
    "-two",
    "+TWO",
  }
  local patch =
    assert(diff.patch_for_rows(lines, { [5] = true, [6] = true, [11] = true, [12] = true }, {}))
  local rows = vim.split((patch:gsub("\n$", "")), "\n", { plain = true })
  equal({
    "diff --git a/one b/one",
    "--- a/one",
    "+++ b/one",
    "@@ -1,1 +1,1 @@",
    "-one",
    "+ONE",
    "diff --git a/two b/two",
    "--- a/two",
    "+++ b/two",
    "@@ -1,1 +1,1 @@",
    "-two",
    "+TWO",
  }, rows)

  -- Picking only the addition of a change pair leaves the removal behind as
  -- context, which is what makes the new line an insertion rather than a
  -- replacement. The recounted header has to say so.
  local addition_only = assert(diff.patch_for_rows(lines, { [6] = true }, {}))
  truthy(addition_only:find("@@ -1,1 +1,2 @@", 1, true), "the narrowed header was not recounted")
end)

test("narrowing re-pairs a change block git printed as removals then additions", function()
  local diff = require("ngit.git.diff")
  -- What `git diff` actually emits for a three-line file whose every line
  -- changed: one run of removals followed by one run of additions.
  local lines = {
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1,3 +1,3 @@",
    "-a",
    "-b",
    "-c",
    "+A",
    "+B",
    "+C",
  }
  local patch = assert(diff.patch_for_rows(lines, { [6] = true, [9] = true }, {}))
  equal({
    "diff --git a/file b/file",
    "--- a/file",
    "+++ b/file",
    "@@ -1,3 +1,3 @@",
    " a",
    "-b",
    "+B",
    " c",
  }, vim.split((patch:gsub("\n$", "")), "\n", { plain = true }))
end)

test("splitting a whole-file addition is refused rather than left to git", function()
  local diff = require("ngit.git.diff")
  local lines = {
    "diff --git a/new b/new",
    "new file mode 100644",
    "--- /dev/null",
    "+++ b/new",
    "@@ -0,0 +1,2 @@",
    "+first",
    "+second",
  }
  local patch, err = diff.patch_for_rows(lines, { [6] = true }, { reverse = true })
  equal(nil, patch)
  truthy(err and err:find("Whole%-file"), "partial reverse of a creation was not explained")

  -- Forward it is an ordinary partial stage, which git handles.
  truthy(diff.patch_for_rows(lines, { [6] = true }, {}))
end)

test("a line selection stages only the rows the reader picked", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "lines.txt"), "a\nb\nc\n")
  git(root, { "add", "lines.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "lines.txt"), "A\nB\nC\n")

  local diff_backend = require("ngit.git.diff")
  local diff = wait_for(function(done)
    diff_backend.load(root, "unstaged", "lines.txt", 3, 10000, done)
  end)
  local selected = {}
  for index, line in ipairs(diff.lines) do
    if line == "-b" or line == "+B" then
      selected[index] = true
    end
  end
  equal(2, vim.tbl_count(selected))

  local patch = assert(diff_backend.patch_for_rows(diff.lines, selected, {}))
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").apply(root, patch, { target = "index" }, done)
  end)
  equal(true, ok)
  equal(nil, err)

  local cached = git(root, { "diff", "--cached", "--", "lines.txt" }).stdout
  truthy(cached:find("+B", 1, true), "the picked line was not staged")
  truthy(not cached:find("+A", 1, true), "an unpicked line was staged")
  truthy(not cached:find("+C", 1, true), "an unpicked line was staged")
  equal("a\nB\nc\n", git(root, { "show", ":lines.txt" }).stdout)
end)

test("discarding a hunk restores only that hunk in the worktree", function()
  local root = repository()
  local original = {}
  for index = 1, 30 do
    original[index] = ("line %02d"):format(index)
  end
  write_file(vim.fs.joinpath(root, "hunks.txt"), table.concat(original, "\n") .. "\n")
  git(root, { "add", "hunks.txt" })
  git(root, { "commit", "-q", "-m", "initial" })

  local changed = vim.deepcopy(original)
  changed[2] = "changed near start"
  changed[29] = "changed near end"
  write_file(vim.fs.joinpath(root, "hunks.txt"), table.concat(changed, "\n") .. "\n")

  local diff_backend = require("ngit.git.diff")
  local diff = wait_for(function(done)
    diff_backend.load(root, "unstaged", "hunks.txt", 3, 10000, done)
  end)
  equal(2, #diff.hunks)
  local patch = assert(diff_backend.patch_at_hunk(diff.lines, diff.hunks[1]))
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").apply(root, patch, { reverse = true, target = "worktree" }, done)
  end)
  equal(true, ok)
  equal(nil, err)

  local content = read_file(vim.fs.joinpath(root, "hunks.txt"))
  truthy(not content:find("changed near start", 1, true), "the discarded hunk survived")
  truthy(content:find("changed near end", 1, true), "an untouched hunk was discarded too")
end)

test("unstaging a later hunk's lines leaves identical-looking lines above it alone", function()
  -- Periodic content with a four-line insertion at the top: after the insertion,
  -- the region four lines above the real change reads exactly like the change's
  -- new side. A reverse patch that names the old-side position lands there.
  local root = repository()
  local head = {}
  for index = 1, 10 do
    head[#head + 1] = "u" .. index
  end
  for _ = 1, 6 do
    vim.list_extend(head, { "p", "q", "r", "s" })
  end
  head[24] = "OLD"
  write_file(vim.fs.joinpath(root, "periodic.txt"), table.concat(head, "\n") .. "\n")
  git(root, { "add", "periodic.txt" })
  git(root, { "commit", "-q", "-m", "initial" })

  local staged = { "a", "b", "c", "d" }
  vim.list_extend(staged, head)
  staged[4 + 24] = "q"
  write_file(vim.fs.joinpath(root, "periodic.txt"), table.concat(staged, "\n") .. "\n")
  git(root, { "add", "periodic.txt" })

  local diff_backend = require("ngit.git.diff")
  local diff = wait_for(function(done)
    diff_backend.load(root, "staged", "periodic.txt", 3, 100000, done)
  end)
  equal(2, #diff.hunks)
  local selected = {}
  for index, line in ipairs(diff.lines) do
    if line == "-OLD" or (line == "+q" and index > diff.hunks[2]) then
      selected[index] = true
    end
  end
  equal(2, vim.tbl_count(selected))

  local patch = assert(diff_backend.patch_for_rows(diff.lines, selected, { reverse = true }))
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").apply(root, patch, { reverse = true, target = "index" }, done)
  end)
  equal(true, ok, err)

  -- Only the second hunk was unstaged: the index is HEAD plus the insertion.
  local expected = { "a", "b", "c", "d" }
  vim.list_extend(expected, head)
  equal(table.concat(expected, "\n") .. "\n", git(root, { "show", ":periodic.txt" }).stdout)
end)

test("reverse-narrowed hunks are positioned by the side the target holds", function()
  local diff = require("ngit.git.diff")
  local lines = {
    "diff --git a/f.txt b/f.txt",
    "index 400d663..567274f 100644",
    "--- a/f.txt",
    "+++ b/f.txt",
    "@@ -1,3 +1,7 @@",
    "+a",
    "+b",
    "+c",
    "+d",
    " u1",
    " u2",
    " u3",
    "@@ -21,7 +25,7 @@ q",
    " r",
    " s",
    " p",
    "-OLD",
    "+q",
    " r",
    " s",
    " p",
  }
  local function headers(patch)
    local found = {}
    for line in patch:gmatch("[^\n]+") do
      if vim.startswith(line, "@@") then
        found[#found + 1] = line
      end
    end
    return found
  end

  -- The first hunk stays staged, so the second is still at its new-side line.
  equal(
    { "@@ -25,7 +25,7 @@" },
    headers(assert(diff.patch_for_rows(lines, { [17] = true, [18] = true }, { reverse = true })))
  )
  -- Reversing both: the second hunk lands four lines earlier once the first is gone.
  local all = { [6] = true, [7] = true, [8] = true, [9] = true, [17] = true, [18] = true }
  equal(
    { "@@ -1,3 +1,7 @@", "@@ -21,7 +25,7 @@" },
    headers(assert(diff.patch_for_rows(lines, all, { reverse = true })))
  )
  -- Staging is unchanged: the index still lacks the insertion.
  equal(
    { "@@ -21,7 +21,7 @@" },
    headers(assert(diff.patch_for_rows(lines, { [17] = true, [18] = true }, {})))
  )
end)

test("a visual selection in the Changes panel stages every file it covers", function()
  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "initial" })
  for _, name in ipairs({ "one.txt", "two.txt", "three.txt" }) do
    write_file(vim.fs.joinpath(root, name), name .. "\n")
  end

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and #session.panels.status.entries == 3
  end, 10))
  local session = require("ngit")._active_session()
  local panel = session.dashboard.panels.status
  vim.api.nvim_set_current_win(panel.window)
  vim.api.nvim_win_set_cursor(panel.window, { session.panels.status.entries[1].row, 0 })
  -- Drives the installed visual-mode mapping rather than the method, so the
  -- selection is read the same way a keypress would produce it.
  vim.api.nvim_feedkeys("Vjs", "x", false)

  truthy(
    vim.wait(10000, function()
      local staged = git(root, { "diff", "--cached", "--name-only" }).stdout
      return select(2, staged:gsub("\n", "\n")) == 2
    end, 10),
    "the visual selection did not stage exactly the covered files"
  )
  local staged = git(root, { "diff", "--cached", "--name-only" }).stdout
  truthy(staged:find("one.txt", 1, true))
  truthy(staged:find("three.txt", 1, true))
  truthy(not staged:find("two.txt", 1, true), "a file outside the selection was staged")
  require("ngit").close()
end)

test("opening a file from the diff lands on the reviewed line", function()
  local root = repository()
  local original = {}
  for index = 1, 20 do
    original[index] = ("line %02d"):format(index)
  end
  write_file(vim.fs.joinpath(root, "jump.txt"), table.concat(original, "\n") .. "\n")
  git(root, { "add", "jump.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  local changed = vim.deepcopy(original)
  changed[12] = "the reviewed line"
  write_file(vim.fs.joinpath(root, "jump.txt"), table.concat(changed, "\n") .. "\n")

  require("ngit").setup({ diff_layout = "unified" })
  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.current_diff_models and session.current_diff_models.unified
  end, 10))
  local session = require("ngit")._active_session()
  session.dashboard:focus_preview()
  local pane = session.current_diff_models.unified.unified
  local target
  for row, kind in pairs(pane.source_kinds) do
    if kind == "add" and pane.source_numbers[row] == 12 then
      target = row
    end
  end
  truthy(target, "the changed row was not found in the preview")

  local path, line = nil, nil
  vim.api.nvim_win_set_cursor(session.dashboard.preview.unified.window, { target, 0 })
  path, line = session:preview_location()
  equal("jump.txt", path)
  equal(12, line)

  session:open_file()
  truthy(vim.wait(10000, function()
    return vim.api.nvim_buf_get_name(0):find("jump.txt", 1, true) ~= nil
  end, 10))
  equal(12, vim.api.nvim_win_get_cursor(0)[1])
  require("ngit").setup()
end)

test("session renders a real repository and closes cleanly", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "visible.txt"), "hello\n")

  require("ngit").open({ cwd = root })
  truthy(
    vim.wait(10000, function()
      local session = require("ngit")._active_session()
      return session and session.status and #session.entries == 1 and session.current_diff ~= nil
    end, 10),
    "session did not finish rendering"
  )

  local session = require("ngit")._active_session()
  local file_lines = vim.api.nvim_buf_get_lines(session.files_buf, 0, -1, false)
  truthy(table.concat(file_lines, "\n"):find("visible.txt", 1, true))
  local preview = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
  truthy(table.concat(preview, "\n"):find("hello", 1, true))
  truthy(not table.concat(preview, "\n"):find("diff --git", 1, true))
  session.cache:clear()
  session:load_preview()
  equal(nil, session.current_diff)
  equal(nil, session.current_diff_models)
  equal(nil, session.dashboard.preview.models)
  local toggled = pcall(session.toggle_diff_layout, session)
  equal(true, toggled)
  require("ngit").close()
  equal(nil, require("ngit")._active_session())
end)

test("opening an explicit directory switches the active repository", function()
  local first = repository()
  local second = repository()
  local first_root = vim.fs.normalize(vim.uv.fs_realpath(first) or first)
  local second_root = vim.fs.normalize(vim.uv.fs_realpath(second) or second)
  write_file(vim.fs.joinpath(first, "first.txt"), "first\n")
  write_file(vim.fs.joinpath(second, "second.txt"), "second\n")

  require("ngit").open({ cwd = first })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.root == first_root and session.status ~= nil
  end, 10))
  require("ngit").open({ cwd = second })
  truthy(
    vim.wait(10000, function()
      local session = require("ngit")._active_session()
      return session and session.root == second_root and session.status ~= nil
    end, 10),
    "explicit cwd did not replace the active repository"
  )
  require("ngit").close()
end)

test("stale status callbacks do not release a newer job", function()
  local root = repository()
  local backend = require("ngit.git.status")
  local original_load = backend.load
  local pending = {}
  backend.load = function(_, callback)
    local job = {
      killed = false,
      kill = function(self)
        self.killed = true
      end,
    }
    pending[#pending + 1] = { callback = callback, job = job }
    return job
  end

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    return #pending == 1
  end, 10))
  local session = require("ngit")._active_session()
  equal(1, #pending)
  session:refresh()
  equal(2, #pending)
  equal(true, pending[1].job.killed)
  pending[1].callback({ files = {}, branch = "old", ahead = 0, behind = 0 })
  equal(pending[2].job, session.status_job)
  pending[2].callback({ files = {}, branch = "main", ahead = 0, behind = 0 })
  equal(nil, session.status_job)
  backend.load = original_load
  require("ngit").close()
end)

test("status-only refresh leaves history collections alone", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "refresh.txt"), "one\n")
  git(root, { "add", "refresh.txt" })
  git(root, { "commit", "-q", "-m", "refresh fixture" })
  write_file(vim.fs.joinpath(root, "refresh.txt"), "two\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session
      and session.status
      and not session.panels.commits.loading
      and not session.panels.branches.loading
      and not session.panels.stashes.loading
  end, 10))
  local session = require("ngit")._active_session()
  local log_backend = require("ngit.git.log")
  local branch_backend = require("ngit.git.branch")
  local stash_backend = require("ngit.git.stash")
  local original_log = log_backend.list
  local original_branch = branch_backend.list
  local original_stash = stash_backend.list
  local collection_calls = 0
  log_backend.list = function(...)
    collection_calls = collection_calls + 1
    return original_log(...)
  end
  branch_backend.list = function(...)
    collection_calls = collection_calls + 1
    return original_branch(...)
  end
  stash_backend.list = function(...)
    collection_calls = collection_calls + 1
    return original_stash(...)
  end

  session:refresh_status()
  truthy(vim.wait(10000, function()
    return not session.panels.status.loading
  end, 10))
  equal(0, collection_calls)
  log_backend.list = original_log
  branch_backend.list = original_branch
  stash_backend.list = original_stash
  require("ngit").close()
end)

test("help reflects configured mappings and omits disabled actions", function()
  require("ngit").setup({ mappings = { stage = "S", refresh = false } })
  local session = require("ngit.ui.session").new(repository())
  local help = table.concat(session:help_lines(), "\n")
  truthy(help:find("S", 1, true))
  truthy(help:find("Stage", 1, true))
  truthy(not help:find("Refresh", 1, true))
  require("ngit").setup()
end)

test("dashboard rejects unusable dimensions before creating a tab", function()
  local previous_columns = vim.o.columns
  local previous_lines = vim.o.lines
  local tab_count = #vim.api.nvim_list_tabpages()
  vim.o.columns = 39
  vim.o.lines = 16
  local ok, err = pcall(require("ngit.ui.dashboard").open, 99999, require("ngit.config").defaults())
  equal(false, ok)
  truthy(tostring(err):find("at least 40 columns by 16 lines", 1, true))
  equal(tab_count, #vim.api.nvim_list_tabpages())
  vim.o.columns = previous_columns
  vim.o.lines = previous_lines
end)

test("dashboard uses unified preview at a narrow usable size", function()
  local previous_columns = vim.o.columns
  local previous_lines = vim.o.lines
  local previous_laststatus = vim.o.laststatus
  local origin = vim.api.nvim_get_current_tabpage()
  vim.o.columns = 50
  vim.o.lines = 16
  vim.o.laststatus = 3
  local dashboard = require("ngit.ui.dashboard").open(99998, require("ngit.config").defaults())
  equal("unified", dashboard.preview.layout)
  truthy(vim.api.nvim_win_is_valid(dashboard.preview.unified.window))
  equal(false, dashboard:supports_side_by_side())
  equal("unified", dashboard:set_preview_layout("side_by_side"))
  equal("unified", dashboard.preview.layout)
  equal(nil, dashboard.preview.left.window)
  local tab = dashboard.tab
  dashboard:dispose()
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose")
  end
  if vim.api.nvim_tabpage_is_valid(origin) then
    vim.api.nvim_set_current_tabpage(origin)
  end
  vim.o.columns = previous_columns
  vim.o.lines = previous_lines
  vim.o.laststatus = previous_laststatus
end)

test("session dashboard keeps all Git contexts visible with the diff on the right", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "views.txt"), "committed\n")
  git(root, { "add", "views.txt" })
  git(root, { "commit", "-q", "-m", "visible commit" })
  git(root, { "branch", "feature/view" })
  write_file(vim.fs.joinpath(root, "views.txt"), "stashed\n")
  git(root, { "stash", "push", "-q", "-m", "visible stash" })
  write_file(vim.fs.joinpath(root, "dashboard.txt"), "visible change\n")

  local previous_statusline = vim.go.statusline
  local previous_laststatus = vim.o.laststatus
  local previous_lualine = package.loaded.lualine
  local lualine_hide_calls = {}
  package.loaded.lualine = {
    hide = function(opts)
      lualine_hide_calls[#lualine_hide_calls + 1] = opts
    end,
  }
  vim.go.statusline = "GLOBAL STATUSLINE SENTINEL"
  vim.o.laststatus = 2
  require("ngit").setup({ diff_layout = "side_by_side" })
  require("ngit").open({ cwd = root })
  truthy(
    vim.wait(10000, function()
      local session = require("ngit")._active_session()
      return session
        and session.status
        and #session.panels.status.entries == 1
        and #session.panels.commits.entries > 0
        and #session.panels.branches.entries >= 2
        and #session.panels.stashes.entries == 1
        and session.current_diff
    end, 10),
    "dashboard did not finish loading every panel"
  )
  local session = require("ngit")._active_session()
  equal("dashboard", session.layout)
  equal("side_by_side", session.dashboard.preview.layout)
  truthy(vim.api.nvim_win_is_valid(session.dashboard.preview.left.window))
  truthy(vim.api.nvim_win_is_valid(session.dashboard.preview.right.window))
  truthy(
    vim.api.nvim_win_get_position(session.dashboard.preview.right.window)[2]
      > vim.api.nvim_win_get_position(session.dashboard.preview.left.window)[2]
  )
  local header_position = vim.api.nvim_win_get_position(session.dashboard.preview.header.window)
  local left_position = vim.api.nvim_win_get_position(session.dashboard.preview.left.window)
  local right_position = vim.api.nvim_win_get_position(session.dashboard.preview.right.window)
  equal(left_position[2], header_position[2])
  truthy(
    vim.api.nvim_win_get_width(session.dashboard.preview.header.window)
      >= right_position[2]
        + vim.api.nvim_win_get_width(session.dashboard.preview.right.window)
        - left_position[2]
  )
  local current_diff = session.current_diff
  session:toggle_diff_layout()
  equal("unified", session.dashboard.preview.layout)
  equal(current_diff, session.current_diff)
  truthy(vim.api.nvim_win_is_valid(session.dashboard.preview.unified.window))
  session:toggle_diff_layout()
  equal("side_by_side", session.dashboard.preview.layout)
  for _, item in ipairs(session.dashboard:preview_windows()) do
    truthy(vim.wo[item.window].statusline:find("NgitStatusline", 1, true))
  end
  equal("GLOBAL STATUSLINE SENTINEL", vim.go.statusline)
  equal(3, vim.o.laststatus)
  equal(false, lualine_hide_calls[1].unhide == true)
  vim.o.laststatus = 2
  vim.api.nvim_set_current_win(session.dashboard.panels.branches.window)
  equal(3, vim.o.laststatus)
  vim.api.nvim_set_current_tabpage(session.origin_tab)
  equal(2, vim.o.laststatus)
  vim.api.nvim_set_current_tabpage(session.tab)
  equal(3, vim.o.laststatus)
  local preview_position = vim.api.nvim_win_get_position(session.preview_win)
  local action_position = vim.api.nvim_win_get_position(session.dashboard.actions.window)
  for _, id in ipairs({ "status", "branches", "commits", "stashes" }) do
    local panel_position = vim.api.nvim_win_get_position(session.dashboard.panels[id].window)
    truthy(preview_position[2] > panel_position[2], "preview must remain right of " .. id)
    equal(0, panel_position[2])
  end
  truthy(action_position[1] > preview_position[1], "action bar must be below the preview")
  equal(1, vim.api.nvim_win_get_height(session.dashboard.actions.window))
  truthy(
    vim.api.nvim_win_get_width(session.dashboard.actions.window)
      > vim.api.nvim_win_get_width(session.dashboard.panels.status.window),
    "action bar must span both dashboard columns"
  )

  local status_selection = session.panels.status.selected
  vim.cmd("NGitLog")
  truthy(vim.wait(10000, function()
    return session.current_view == "commits"
      and session.active_panel == "commits"
      and session.current_diff
  end, 10))
  equal(status_selection, session.panels.status.selected)
  equal("visible commit", session.panels.commits.entries[1].commit.subject)

  session:switch_view("branches")
  truthy(vim.wait(10000, function()
    return session.current_view == "branches" and session.current_diff
  end, 10))
  session:select_relative(1)
  local branch_selection = session.panels.branches.selected
  session:switch_view("status")
  session:switch_view("branches")
  equal(branch_selection, session.panels.branches.selected)

  session:switch_view("stashes")
  truthy(vim.wait(10000, function()
    return session.current_view == "stashes" and session.current_diff
  end, 10))
  truthy(session.panels.stashes.entries[1].stash.subject:find("visible stash", 1, true))

  local stash_lines =
    vim.api.nvim_buf_get_lines(session.dashboard.panels.stashes.buffer, 0, -1, false)
  truthy(table.concat(stash_lines, "\n"):find("visible stash", 1, true))
  local commit_extmarks = vim.api.nvim_buf_get_extmarks(
    session.dashboard.panels.commits.buffer,
    session.dashboard.namespace,
    0,
    -1,
    { details = true }
  )
  local commit_groups = {}
  for _, mark in ipairs(commit_extmarks) do
    commit_groups[mark[4].hl_group] = true
  end
  -- Each panel header leads with the bracketed key that focuses it.
  for index, id in ipairs(require("ngit.ui.dashboard").panel_order) do
    local winbar = vim.wo[session.dashboard.panels[id].window].winbar
    truthy(
      winbar:find(("[%d]"):format(index), 1, true),
      ("%s header is missing its [%d] hint: %s"):format(id, index, winbar)
    )
  end
  -- Only the focused panel accents its index; the rest stay muted.
  for _, id in ipairs(require("ngit.ui.dashboard").panel_order) do
    local accented = vim.wo[session.dashboard.panels[id].window].winbar:find(
      "NgitPanelIndex",
      1,
      true
    ) ~= nil
    equal(id == session.active_panel, accented, id .. " index accent is wrong")
  end

  truthy(commit_groups.NgitCommitHash)
  -- The commits panel carries no date column; stashes still do.
  truthy(not commit_groups.NgitDate)
  local stash_groups = {}
  for _, mark in
    ipairs(
      vim.api.nvim_buf_get_extmarks(
        session.dashboard.panels.stashes.buffer,
        session.dashboard.namespace,
        0,
        -1,
        { details = true }
      )
    )
  do
    stash_groups[mark[4].hl_group] = true
  end
  truthy(stash_groups.NgitStashRef)
  truthy(stash_groups.NgitDate)
  local action_lines = vim.api.nvim_buf_get_lines(session.dashboard.actions.buffer, 0, -1, false)
  truthy(table.concat(action_lines, ""):find("Apply", 1, true))
  truthy(
    vim.fn.strdisplaywidth(action_lines[1])
      <= vim.api.nvim_win_get_width(session.dashboard.actions.window)
  )
  session.dashboard:resize()
  equal(1, vim.api.nvim_win_get_height(session.dashboard.actions.window))
  local dashboard_buffers = session.dashboard:all_buffers()
  require("ngit").close()
  equal(2, vim.o.laststatus)
  equal("GLOBAL STATUSLINE SENTINEL", vim.go.statusline)
  truthy(lualine_hide_calls[#lualine_hide_calls].unhide == true)
  package.loaded.lualine = previous_lualine
  require("ngit").setup()
  vim.go.statusline = previous_statusline
  vim.o.laststatus = previous_laststatus
  for _, buffer in ipairs(dashboard_buffers) do
    equal(false, vim.api.nvim_buf_is_valid(buffer))
  end
end)

test("git refusals printed on stdout reach the caller", function()
  local runner = require("ngit.git.runner")
  equal(
    "On branch main\nnothing to commit, working tree clean",
    runner.error_message({
      code = 1,
      stdout = "On branch main\nnothing to commit, working tree clean\n",
      stderr = "",
    })
  )
  equal(
    "fatal: bad revision",
    runner.error_message({ code = 128, stdout = "ignored", stderr = "fatal: bad revision\n" })
  )
  equal("Git exited with status 3", runner.error_message({ code = 3, stdout = "", stderr = "" }))
  local long = runner.error_message({ code = 1, stdout = string.rep("noise\n", 500), stderr = "" })
  truthy(#long < 200, "an oversized stream must be summarized, got " .. #long)
end)

test("committing with nothing staged explains why instead of an exit code", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })

  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").commit(root, "no changes", false, done)
  end)
  equal(false, ok)
  truthy(err:find("nothing to commit", 1, true), "unexpected message: " .. tostring(err))
end)

test("unstaging a rename clears both of its index slots", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "old.txt"), string.rep("content line\n", 20))
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  os.rename(vim.fs.joinpath(root, "old.txt"), vim.fs.joinpath(root, "new.txt"))
  git(root, { "add", "-A" })

  local staged = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(1, #staged.files)
  equal("renamed", staged.files[1].kind)
  equal("old.txt", staged.files[1].old_path)

  local ok = wait_for(function(done)
    require("ngit.git.mutate").unstage_file(root, { "new.txt", "old.txt" }, done)
  end)
  equal(true, ok)

  -- The rename becomes an untracked new.txt plus a worktree deletion of
  -- old.txt: the real state, with nothing left staged on either path.
  local after = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  local paths = {}
  for _, file in ipairs(after.files) do
    truthy(
      file.index_status == "." or file.index_status == "?",
      ("%s is still staged as %q"):format(file.path, file.index_status)
    )
    paths[file.path] = true
  end
  truthy(paths["new.txt"], "the renamed file should now be untracked")
  truthy(paths["old.txt"], "the original path should show as deleted")
end)

test("discarding a staged change restores the file and empties the index", function()
  local root = repository()
  local path = vim.fs.joinpath(root, "a.txt")
  write_file(path, "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  write_file(path, "two\n")
  git(root, { "add", "-A" })

  local ok = wait_for(function(done)
    require("ngit.git.mutate").discard_all_changes(root, { "a.txt" }, done)
  end)
  equal(true, ok)
  equal("one\n", read_file(path))

  local after = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(0, #after.files)
end)

test("discarding a staged addition removes the file from the worktree", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "base.txt"), "base\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  local added = vim.fs.joinpath(root, "added.txt")
  write_file(added, "new\n")
  git(root, { "add", "-A" })

  local ok = wait_for(function(done)
    require("ngit.git.mutate").discard_all_changes(root, { "added.txt" }, done)
  end)
  equal(true, ok)
  equal(nil, vim.uv.fs_stat(added))
end)

test("an untracked file can be deleted through the discard action", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "a\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  local junk = vim.fs.joinpath(root, "junk.txt")
  write_file(junk, "junk\n")

  local ok = wait_for(function(done)
    require("ngit.git.mutate").remove_untracked(root, "junk.txt", done)
  end)
  equal(true, ok)
  equal(nil, vim.uv.fs_stat(junk))
end)

test("discard prompts before touching an untracked file and honours cancel", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "a\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  local junk = vim.fs.joinpath(root, "junk.txt")
  write_file(junk, "junk\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and #session.panels.status.entries == 1
  end, 10))

  local session = require("ngit")._active_session()
  local prompts = {}
  local previous = vim.ui.select
  vim.ui.select = function(_, opts, callback)
    prompts[#prompts + 1] = opts.prompt
    callback("Cancel")
  end
  session:discard()
  vim.ui.select = previous

  equal(1, #prompts)
  truthy(prompts[1]:find("Delete untracked file junk.txt", 1, true), prompts[1])
  truthy(vim.uv.fs_stat(junk) ~= nil, "cancelling must leave the file in place")
  require("ngit").close()
end)

test("X in the diff never falls back to discarding the whole file", function()
  local root = repository()
  local original = {}
  for index = 1, 30 do
    original[index] = ("line %02d"):format(index)
  end
  write_file(vim.fs.joinpath(root, "guarded.txt"), table.concat(original, "\n") .. "\n")
  git(root, { "add", "guarded.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  local changed = vim.deepcopy(original)
  changed[2] = "changed near start"
  changed[29] = "changed near end"
  local worktree = table.concat(changed, "\n") .. "\n"
  write_file(vim.fs.joinpath(root, "guarded.txt"), worktree)

  require("ngit").setup({ diff_layout = "unified" })
  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.current_diff_models and session.current_diff_models.unified
  end, 10))
  local session = require("ngit")._active_session()
  session.dashboard:focus_preview()
  local pane = session.current_diff_models.unified.unified
  local outside
  for row = 1, vim.api.nvim_buf_line_count(0) do
    if not pane.row_hunks[row] then
      outside = row
      break
    end
  end
  truthy(outside, "every preview row belongs to a hunk")
  vim.api.nvim_win_set_cursor(session.dashboard.preview.unified.window, { outside, 0 })

  local prompts = {}
  local original_select = vim.ui.select
  vim.ui.select = function(items, opts, on_choice)
    prompts[#prompts + 1] = opts.prompt
    on_choice(items[#items], #items)
  end
  session:discard()
  -- While the preview reloads there are no models; the diff still has focus.
  local models = session.current_diff_models
  session.current_diff_models = nil
  local patch, err = session:selection_patch(true)
  session.current_diff_models = models
  vim.ui.select = original_select

  equal({}, prompts, "a whole-file discard was offered from the diff")
  equal(worktree, read_file(vim.fs.joinpath(root, "guarded.txt")))
  equal(nil, patch)
  truthy(err and err:find("loading", 1, true), err)
  require("ngit").close()
  require("ngit").setup()
end)

test("hard reset and restore refuse while a buffer has unsaved edits", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "kept.txt"), "committed\n")
  git(root, { "add", "kept.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "kept.txt"), "on disk\n")
  vim.cmd.edit(vim.fs.joinpath(root, "kept.txt"))
  local buffer = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "unsaved" })
  truthy(vim.bo[buffer].modified)

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session
      and session.status ~= nil
      and #(session.panels.commits.data or {}) > 0
  end, 10))
  local session = require("ngit")._active_session()

  local prompts = {}
  local original_select, original_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, opts, on_choice)
    prompts[#prompts + 1] = opts.prompt
    for index, item in ipairs(items) do
      if vim.startswith(item, "git reset --hard") or vim.startswith(item, "Restore from") then
        on_choice(item, index)
        return
      end
    end
    on_choice(items[#items], #items)
  end
  vim.ui.input = function(_, on_confirm)
    on_confirm("HEAD")
  end

  session:switch_view("commits")
  session:reset()
  session:switch_view("status")
  session:file_menu()
  vim.ui.select, vim.ui.input = original_select, original_input

  -- Each menu opened, but neither reached its confirmation or git.
  equal(2, #prompts, vim.inspect(prompts))
  equal("on disk\n", read_file(vim.fs.joinpath(root, "kept.txt")))
  require("ngit").close()
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("a revert rereads open buffers of the files it rewrote", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "shown.txt"), "old\n")
  git(root, { "add", "shown.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "shown.txt"), "a longer new line\n")
  git(root, { "commit", "-q", "-am", "change" })
  vim.cmd.edit(vim.fs.joinpath(root, "shown.txt"))
  local buffer = vim.api.nvim_get_current_buf()
  equal({ "a longer new line" }, vim.api.nvim_buf_get_lines(buffer, 0, -1, false))

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and #(session.panels.commits.data or {}) > 0
  end, 10))
  local session = require("ngit")._active_session()
  session:switch_view("commits")
  local original_select = vim.ui.select
  vim.ui.select = function(items, _, on_choice)
    on_choice(items[#items], #items)
  end
  session:revert()
  vim.ui.select = original_select

  truthy(vim.wait(10000, function()
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)[1] == "old"
  end, 10), "the open buffer still shows the reverted content")
  require("ngit").close()
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("stage all and unstage all cover every pending change", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  write_file(vim.fs.joinpath(root, "a.txt"), "two\n")
  write_file(vim.fs.joinpath(root, "b.txt"), "new\n")

  local mutate = require("ngit.git.mutate")
  equal(
    true,
    wait_for(function(done)
      mutate.stage_all(root, done)
    end)
  )
  local staged = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(2, #staged.files)
  for _, file in ipairs(staged.files) do
    truthy(file.index_status ~= "." and file.index_status ~= "?", file.path .. " is not staged")
  end

  equal(
    true,
    wait_for(function(done)
      mutate.unstage_all(root, done)
    end)
  )
  local after = wait_for(function(done)
    require("ngit.git.status").load(root, done)
  end)
  equal(2, #after.files)
  for _, file in ipairs(after.files) do
    truthy(
      file.index_status == "." or file.index_status == "?",
      ("%s is still staged as %q"):format(file.path, file.index_status)
    )
  end
end)

test("the commit editor is refused before opening when nothing is staged", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  write_file(vim.fs.joinpath(root, "a.txt"), "two\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and #session.panels.status.entries == 1
  end, 10))

  local session = require("ngit")._active_session()
  local messages = {}
  local previous = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = tostring(message)
  end
  session:prompt_commit(false)
  vim.notify = previous

  equal(nil, session.commit_editor)
  equal(1, #messages)
  truthy(messages[1]:find("Nothing is staged", 1, true), messages[1])
  require("ngit").close()
end)

test("amending an unborn branch reports the cause instead of a git fatal", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status ~= nil
  end, 10))

  local session = require("ngit")._active_session()
  local messages = {}
  local previous = vim.notify
  vim.notify = function(message)
    messages[#messages + 1] = tostring(message)
  end
  session:prompt_commit(true)
  truthy(vim.wait(10000, function()
    return #messages > 0
  end, 10))
  vim.notify = previous

  equal(nil, session.commit_editor)
  truthy(messages[1]:find("no commit to amend", 1, true), messages[1])
  require("ngit").close()
end)

test("toggling the diff layout preserves the weighted panel heights", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "init" })
  write_file(vim.fs.joinpath(root, "a.txt"), "two\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and session.current_diff ~= nil
  end, 10))

  local session = require("ngit")._active_session()
  local Dashboard = require("ngit.ui.dashboard")
  local function heights()
    local result = {}
    for _, id in ipairs(Dashboard.panel_order) do
      result[id] = vim.api.nvim_win_get_height(session.dashboard.panels[id].window)
    end
    return result
  end

  local before = heights()
  session:toggle_diff_layout()
  session:toggle_diff_layout()
  equal(before, heights())
  require("ngit").close()
end)

test("commit previews carry the message and stat into the scrollable body", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "a.txt"), "one\n")
  git(root, { "add", "-A" })
  git(root, { "commit", "-qm", "feat: a subject line\n\nA body paragraph worth reading." })

  local commits = wait_for(function(done)
    require("ngit.git.log").list(root, {}, done)
  end)
  equal(1, #commits)
  local diff = wait_for(function(done)
    require("ngit.git.log").show(root, commits[1].oid, 1024 * 1024, done)
  end)

  local view = require("ngit.ui.diff_view")
  local split = view.split(diff, { title = "commit" })
  local body = table.concat(split.left.lines, "\n")
  truthy(body:find("A body paragraph worth reading.", 1, true), "message body is missing")
  truthy(body:find("feat: a subject line", 1, true), "subject is missing")

  -- The header window stays two lines so its height never shifts the layout.
  equal(2, #split.header)
  local unified = view.unified(diff, { title = "commit" }, split)
  truthy(
    table.concat(unified.unified.lines, "\n"):find("A body paragraph worth reading.", 1, true),
    "unified view dropped the message body"
  )
end)

test("the diff gutter draws numbers for a window that is not the current one", function()
  local gutter = require("ngit.ui.gutter")
  local buffer = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "a", "b", "c" })
  gutter.attach(buffer, {
    source_numbers = { 12, false, 14 },
    source_kinds = { "add", false, "delete" },
  })

  -- Neovim evaluates 'statuscolumn' for each window while some other window
  -- holds focus, so the pane has to be found through g:statusline_winid.
  -- Reading the current buffer instead silently drew a blank column.
  vim.cmd("new")
  local window = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(window, buffer)
  vim.cmd("wincmd p")
  truthy(
    vim.api.nvim_get_current_buf() ~= buffer,
    "the drawn buffer must not be the current one for this test to mean anything"
  )

  local previous_winid = vim.g.statusline_winid
  vim.g.statusline_winid = window

  vim.v.lnum = 1
  local added = gutter.render()
  truthy(added:find("12", 1, true), "missing source number, got " .. vim.inspect(added))
  truthy(added:find("NgitDiffAddNumber", 1, true), added)
  vim.v.lnum = 3
  local deleted = gutter.render()
  truthy(deleted:find("NgitDiffDeleteNumber", 1, true))

  -- The tinted number carries the side, so no +/- marker is drawn.
  truthy(not added:find("+", 1, true), "unexpected marker: " .. added)
  truthy(not deleted:find("-", 1, true), "unexpected marker: " .. deleted)

  -- Two-digit numbers must not reserve room for five.
  equal(3, gutter.width(buffer))
  vim.v.lnum = 2
  equal(gutter.width(buffer), #gutter.render())

  gutter.detach(buffer)
  vim.v.lnum = 1
  equal("", gutter.render())
  equal(0, gutter.width(buffer))

  vim.g.statusline_winid = previous_winid
  if vim.api.nvim_win_is_valid(window) then
    vim.api.nvim_win_close(window, true)
  end
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("reselecting does not refire FileType on the preview buffers", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "one.txt"), "a\n")
  write_file(vim.fs.joinpath(root, "two.txt"), "b\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and #session.panels.status.entries == 2
  end, 10))
  local session = require("ngit")._active_session()

  -- Assigning 'filetype' fires FileType even when the value does not change,
  -- and it costs about a millisecond per buffer. Moving the selection must not
  -- pay that on every keypress.
  local previews = {
    [session.dashboard.preview.left.buffer] = true,
    [session.dashboard.preview.right.buffer] = true,
    [session.dashboard.preview.unified.buffer] = true,
  }
  local fired = 0
  local group = vim.api.nvim_create_augroup("ngit_filetype_probe", { clear = true })
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    callback = function(event)
      if previews[event.buf] then
        fired = fired + 1
      end
    end,
  })

  for _ = 1, 10 do
    session:select_relative(1)
  end
  pcall(vim.api.nvim_del_augroup_by_id, group)
  equal(0, fired)
  require("ngit").close()
end)

test("a transparent background is not painted over by alignment gaps", function()
  local highlights = require("ngit.ui.highlights")
  local restore = vim.api.nvim_get_hl(0, { name = "Normal", link = false })

  -- Transparent: Normal carries no background, so the terminal shows through.
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xc8c8d4 })
  highlights.setup()
  local transparent = vim.api.nvim_get_hl(0, { name = "NgitDiffFiller", link = false })
  equal(nil, transparent.bg)
  truthy(transparent.fg ~= nil, "filler rows still need a foreground")

  -- Added and removed rows must keep their tint either way; a diff without
  -- them is unreadable, transparent terminal or not.
  for _, name in ipairs({ "NgitDiffAdd", "NgitDiffDelete", "NgitDiffChange" }) do
    truthy(
      vim.api.nvim_get_hl(0, { name = name, link = false }).bg ~= nil,
      name .. " must keep its background"
    )
  end

  -- Opaque: the gap gets its faint tint back.
  vim.api.nvim_set_hl(0, "Normal", { fg = 0xc8c8d4, bg = 0x14161b })
  highlights.setup()
  local opaque = vim.api.nvim_get_hl(0, { name = "NgitDiffFiller", link = false })
  truthy(opaque.bg ~= nil, "an opaque background should tint alignment gaps")
  truthy(opaque.bg ~= 0x14161b, "the tint should differ from Normal")

  vim.api.nvim_set_hl(0, "Normal", restore)
  highlights.setup()
end)

test("branch rows mark only the checked-out branch and dim the remote prefix", function()
  local render = require("ngit.ui.render")
  local current = render.branch(true, "main", "chore: x", "", false)
  local other = render.branch(false, "fix/tab", "fix: y", "", false)
  local remote = render.branch(false, "origin/fix/tab", "fix: y", "", true)

  truthy(current.text:find("* main", 1, true), current.text)
  truthy(not other.text:find("*", 1, true), "only the current branch is marked: " .. other.text)
  -- A remote ref used to carry a literal "r", which read as part of the name.
  truthy(not remote.text:find("r origin", 1, true), remote.text)
  -- Locals and remotes must start in the same column so the list scans clean.
  equal(other.text:find("fix/tab", 1, true), remote.text:find("origin", 1, true))

  local spans = {}
  for _, span in ipairs(remote.spans) do
    spans[span.group] = remote.text:sub(span.col + 1, span.end_col)
  end
  equal("origin/", spans.NgitPathDim)
  equal("fix/tab", spans.NgitBranchRemote)
  -- A remote name with no slash must not lose its text.
  truthy(render.branch(false, "weird", "s", "", true).text:find("weird", 1, true))
end)

test("commit ages stay compact and never outgrow the column", function()
  local render = require("ngit.ui.render")
  local now = 1800000000
  local function age(seconds)
    return render.age(now - seconds, now)
  end

  equal("now", age(0))
  equal("now", age(44))
  equal("45s", age(45))
  equal("59s", age(59))
  equal("1m", age(60))
  equal("59m", age(3599))
  equal("1h", age(3600))
  equal("23h", age(86399))
  equal("1d", age(86400))
  equal("6d", age(604799))
  equal("1w", age(604800))
  equal("4w", age(2629799))
  equal("1mo", age(2629800))
  equal("11mo", age(31557599))
  equal("1y", age(31557600))
  equal("10y", age(31557600 * 10))

  equal("?", render.age(nil, now))
  equal("?", render.age(0, now))
  -- A commit dated in the future must not render a negative age.
  equal("now", render.age(now + 5000, now))

  for _, seconds in ipairs({ 0, 45, 3600, 86400, 604800, 2629800, 31557600 * 99 }) do
    truthy(#age(seconds) <= 4, ("age %q exceeds the column"):format(age(seconds)))
  end

  -- Stash subjects must start at the same offset whatever the age reads.
  local short = render.stash("stash@{0}", "1d", "on main: a subject")
  local long = render.stash("stash@{0}", "11mo", "on main: a subject")
  equal(
    short.text:find("on main: a subject", 1, true),
    long.text:find("on main: a subject", 1, true)
  )

  -- Commits carry no date column at all; their date lives in the preview.
  local commit = render.commit("abcdef12", "feat: a subject", "")
  equal("  abcdef12  feat: a subject", commit.text)
end)

test("the gutter reserves only as many columns as the numbers need", function()
  local gutter = require("ngit.ui.gutter")
  local function width_for(highest)
    local buffer = vim.api.nvim_create_buf(false, true)
    gutter.attach(buffer, { source_numbers = { highest }, source_kinds = { "context" } })
    local width = gutter.width(buffer)
    gutter.detach(buffer)
    vim.api.nvim_buf_delete(buffer, { force = true })
    return width
  end

  equal(3, width_for(7))
  equal(3, width_for(99))
  equal(4, width_for(100))
  equal(5, width_for(4000))

  -- A pane with no numbered rows at all, such as a metadata-only preview,
  -- must not indent every line by an empty column.
  local buffer = vim.api.nvim_create_buf(false, true)
  gutter.attach(buffer, { source_numbers = { false, false }, source_kinds = { false, false } })
  equal(0, gutter.width(buffer))
  gutter.detach(buffer)
  vim.api.nvim_buf_delete(buffer, { force = true })
end)

test("help opens as a grouped float that closes on q", function()
  local mappings = require("ngit.config").defaults().mappings
  local window = require("ngit.ui.help").open(mappings)
  truthy(window and vim.api.nvim_win_is_valid(window))

  local buffer = vim.api.nvim_win_get_buf(window)
  local text = table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n")
  truthy(text:find("Changes", 1, true))
  truthy(text:find("Stage everything", 1, true))
  truthy(text:find("Conflicts and remotes", 1, true))
  truthy(vim.api.nvim_win_get_config(window).relative == "editor")

  vim.api.nvim_set_current_win(window)
  vim.api.nvim_feedkeys("q", "x", false)
  equal(false, vim.api.nvim_win_is_valid(window))
end)

test("tags appear as refs of their own and report the commit they name", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "tagged.txt"), "one\n")
  git(root, { "add", "tagged.txt" })
  git(root, { "commit", "-q", "-m", "first" })
  local head = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)

  local branch_backend = require("ngit.git.branch")
  local lightweight = wait_for(function(done)
    branch_backend.create_tag(root, "v0-light", "HEAD", nil, done)
  end)
  equal(true, lightweight)
  local annotated, annotate_err = wait_for(function(done)
    branch_backend.create_tag(root, "v1", "HEAD", "release one", done)
  end)
  equal(true, annotated)
  equal(nil, annotate_err)

  local refs = wait_for(function(done)
    branch_backend.list(root, done)
  end)
  local by_name = {}
  for _, ref in ipairs(refs) do
    by_name[ref.name] = ref
  end
  truthy(by_name["v1"], "the annotated tag is missing from the ref list")
  equal("tag", by_name["v1"].scope)
  equal(true, by_name["v1"].tag)
  -- An annotated tag's own object name is not the commit, so the peeled name is
  -- what a diff or a checkout has to use.
  equal(head, by_name["v1"].oid)
  equal(head, by_name["v0-light"].oid)
  equal("local", by_name["main"].scope)

  local dropped = wait_for(function(done)
    branch_backend.delete_tag(root, "v0-light", done)
  end)
  equal(true, dropped)
  truthy(not git(root, { "tag", "--list" }).stdout:find("v0%-light"))
end)

test("branches can be renamed and given or stripped of an upstream", function()
  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "initial" })
  local branch_backend = require("ngit.git.branch")

  local created = wait_for(function(done)
    branch_backend.create(root, "topic", nil, done)
  end)
  equal(true, created)
  local renamed, rename_err = wait_for(function(done)
    branch_backend.rename(root, "topic", "topic/renamed", done)
  end)
  equal(true, renamed)
  equal(nil, rename_err)
  truthy(git(root, { "branch", "--list", "topic/renamed" }).stdout:find("topic/renamed", 1, true))

  local tracked, track_err = wait_for(function(done)
    branch_backend.set_upstream(root, "topic/renamed", "main", done)
  end)
  equal(true, tracked)
  equal(nil, track_err)
  equal(
    "main",
    vim.trim(git(root, { "rev-parse", "--abbrev-ref", "topic/renamed@{upstream}" }).stdout)
  )

  local cleared = wait_for(function(done)
    branch_backend.set_upstream(root, "topic/renamed", nil, done)
  end)
  equal(true, cleared)
  local after = git(root, {
    "rev-parse",
    "--abbrev-ref",
    "topic/renamed@{upstream}",
  }, { accept = { [128] = true } })
  truthy(after.code ~= 0, "the upstream survived being unset")

  equal("origin", (branch_backend.split_remote("origin/topic/renamed")))
  equal("topic/renamed", select(2, branch_backend.split_remote("origin/topic/renamed")))
end)

test("a commit can be reverted and reset onto", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "revert.txt"), "keep\n")
  git(root, { "add", "revert.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  local base = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)
  write_file(vim.fs.joinpath(root, "revert.txt"), "keep\nregret\n")
  git(root, { "commit", "-q", "-am", "add regret" })
  local regret = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)

  local reverted, revert_err = wait_for(function(done)
    require("ngit.git.sequencer").start(root, "revert", regret, done)
  end)
  equal(true, reverted)
  equal(nil, revert_err)
  equal("keep\n", read_file(vim.fs.joinpath(root, "revert.txt")))
  truthy(git(root, { "log", "-1", "--format=%s" }).stdout:find("Revert", 1, true))

  local reset, reset_err = wait_for(function(done)
    require("ngit.git.mutate").reset(root, "hard", base, done)
  end)
  equal(true, reset)
  equal(nil, reset_err)
  equal(base, vim.trim(git(root, { "rev-parse", "HEAD" }).stdout))
end)

test("an interactive rebase plan drops and reorders the commits it names", function()
  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "base" })
  for _, name in ipairs({ "one", "two", "three" }) do
    write_file(vim.fs.joinpath(root, name .. ".txt"), name .. "\n")
    git(root, { "add", name .. ".txt" })
    git(root, { "commit", "-q", "-m", name })
  end

  local sequencer = require("ngit.git.sequencer")
  local steps, todo_err = wait_for(function(done)
    sequencer.rebase_todo(root, "HEAD~3", done)
  end)
  equal(nil, todo_err)
  equal(3, #steps)
  -- Oldest first, which is the order git's todo list is read in.
  equal("one", steps[1].subject)
  equal("three", steps[3].subject)

  -- A reword becomes a pick plus a break, so the rebase stops with the commit at
  -- HEAD where the ordinary amend action can reach it.
  equal(
    {
      "pick " .. steps[1].oid .. " one",
      "pick " .. steps[2].oid .. " two",
      "break",
      "drop " .. steps[3].oid .. " three",
    },
    sequencer.todo_lines({
      { action = "pick", oid = steps[1].oid, subject = "one" },
      { action = "reword", oid = steps[2].oid, subject = "two" },
      { action = "drop", oid = steps[3].oid, subject = "three" },
    })
  )

  steps[2].action = "drop"
  local ok, err = wait_for(function(done)
    sequencer.rebase_with_todo(root, "HEAD~3", steps, done)
  end)
  equal(true, ok, err)
  local subjects = git(root, { "log", "--format=%s", "-3" }).stdout
  truthy(subjects:find("three", 1, true), "the kept commits did not survive")
  truthy(not subjects:find("two", 1, true), "the dropped commit survived")
end)

test("autosquash folds a fixup commit into the one it names", function()
  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "base" })
  write_file(vim.fs.joinpath(root, "squash.txt"), "first\n")
  git(root, { "add", "squash.txt" })
  git(root, { "commit", "-q", "-m", "feature" })
  local target = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)

  write_file(vim.fs.joinpath(root, "squash.txt"), "first\nsecond\n")
  git(root, { "add", "squash.txt" })
  local committed, commit_err = wait_for(function(done)
    require("ngit.git.mutate").commit(root, "", { fixup = target }, done)
  end)
  equal(true, committed)
  equal(nil, commit_err)
  equal(3, tonumber(vim.trim(git(root, { "rev-list", "--count", "HEAD" }).stdout)))

  local ok, err = wait_for(function(done)
    require("ngit.git.sequencer").rebase_autosquash(root, "HEAD~2", done)
  end)
  equal(true, ok, err)
  equal(2, tonumber(vim.trim(git(root, { "rev-list", "--count", "HEAD" }).stdout)))
  equal("first\nsecond\n", read_file(vim.fs.joinpath(root, "squash.txt")))
end)

test("stash variants keep the index, take the staged half, and name paths", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "kept.txt"), "one\n")
  write_file(vim.fs.joinpath(root, "other.txt"), "one\n")
  git(root, { "add", "." })
  git(root, { "commit", "-q", "-m", "initial" })

  local stash_backend = require("ngit.git.stash")
  write_file(vim.fs.joinpath(root, "kept.txt"), "two\n")
  git(root, { "add", "kept.txt" })
  write_file(vim.fs.joinpath(root, "other.txt"), "two\n")

  local ok, err = wait_for(function(done)
    stash_backend.push(root, "keeping the index", { keep_index = true }, done)
  end)
  equal(true, ok, err)
  -- --keep-index leaves the staged content in place, which is the whole point:
  -- the build can run against exactly what is about to be committed.
  truthy(git(root, { "diff", "--cached", "--name-only" }).stdout:find("kept.txt", 1, true))

  local stashes = wait_for(function(done)
    stash_backend.list(root, done)
  end)
  equal(1, #stashes)
  local applied, apply_err = wait_for(function(done)
    stash_backend.apply(root, stashes[1], { index = true }, done)
  end)
  -- Applying over content the stash already restored can conflict; either way the
  -- call has to report rather than throw.
  truthy(applied == true or apply_err ~= nil)

  git(root, { "checkout", "--", "." })
  git(root, { "stash", "clear" })
  write_file(vim.fs.joinpath(root, "kept.txt"), "three\n")
  local by_path, path_err = wait_for(function(done)
    stash_backend.push(root, "one path only", { paths = { "kept.txt" } }, done)
  end)
  equal(true, by_path, path_err)
  equal("one\n", read_file(vim.fs.joinpath(root, "kept.txt")))
end)

test("conflict markers are parsed and one block at a time can take a side", function()
  local conflict = require("ngit.git.conflict")
  local lines = {
    "before",
    "<<<<<<< HEAD",
    "ours one",
    "=======",
    "theirs one",
    ">>>>>>> topic",
    "between",
    "<<<<<<< HEAD",
    "ours two",
    "=======",
    "theirs two",
    ">>>>>>> topic",
    "after",
  }
  local blocks = conflict.parse_markers(lines)
  equal(2, #blocks)
  equal(2, blocks[1].start)
  equal(6, blocks[1].finish)
  equal("HEAD", blocks[1].ours_label)
  equal("topic", blocks[1].theirs_label)

  equal({
    "before",
    "ours one",
    "between",
    "<<<<<<< HEAD",
    "ours two",
    "=======",
    "theirs two",
    ">>>>>>> topic",
    "after",
  }, conflict.resolve_lines(lines, { blocks[1] }, "ours"))

  equal({
    "before",
    "ours one",
    "theirs one",
    "between",
    "ours two",
    "theirs two",
    "after",
  }, conflict.resolve_lines(lines, blocks, "both"))

  -- diff3 style puts the common ancestor between ||||||| and =======, and "ours"
  -- has to stop at the first of the two.
  local diff3 = {
    "<<<<<<< HEAD",
    "ours",
    "||||||| base",
    "original",
    "=======",
    "theirs",
    ">>>>>>> topic",
  }
  local diff3_blocks = conflict.parse_markers(diff3)
  equal(1, #diff3_blocks)
  equal(3, diff3_blocks[1].base)
  equal({ "ours" }, conflict.resolve_lines(diff3, diff3_blocks, "ours"))
end)

test("a real conflict can be resolved one block at a time and then staged", function()
  local root = repository()
  local base = { "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" }
  write_file(vim.fs.joinpath(root, "both.txt"), table.concat(base, "\n") .. "\n")
  git(root, { "add", "both.txt" })
  git(root, { "commit", "-q", "-m", "base" })

  git(root, { "switch", "-q", "-c", "topic" })
  local theirs = vim.deepcopy(base)
  theirs[1] = "theirs first"
  theirs[9] = "theirs last"
  write_file(vim.fs.joinpath(root, "both.txt"), table.concat(theirs, "\n") .. "\n")
  git(root, { "commit", "-q", "-am", "topic edits" })

  git(root, { "switch", "-q", "main" })
  local ours = vim.deepcopy(base)
  ours[1] = "ours first"
  ours[9] = "ours last"
  write_file(vim.fs.joinpath(root, "both.txt"), table.concat(ours, "\n") .. "\n")
  git(root, { "commit", "-q", "-am", "main edits" })
  git(root, { "merge", "topic" }, { accept = { [1] = true } })

  local conflict = require("ngit.git.conflict")
  local blocks = assert(conflict.blocks(root, "both.txt"))
  equal(2, #blocks)

  -- Resolving only the first block leaves the file conflicted, so it must not be
  -- staged yet: doing so would mark the merge resolved with markers still in it.
  local ok, err = wait_for(function(done)
    conflict.resolve(root, "both.txt", "ours", blocks[1].start, done)
  end)
  equal(true, ok, err)
  local partial = read_file(vim.fs.joinpath(root, "both.txt"))
  truthy(partial:find("ours first", 1, true))
  truthy(not partial:find("theirs first", 1, true))
  truthy(partial:find("<<<<<<<", 1, true), "the second conflict was resolved too")
  truthy(
    git(root, { "diff", "--name-only", "--diff-filter=U" }).stdout:find("both.txt", 1, true),
    "the file was staged while still conflicted"
  )

  local remaining = assert(conflict.blocks(root, "both.txt"))
  local second, second_err = wait_for(function(done)
    conflict.resolve(root, "both.txt", "theirs", remaining[1].start, done)
  end)
  equal(true, second, second_err)
  local resolved = read_file(vim.fs.joinpath(root, "both.txt"))
  truthy(resolved:find("theirs last", 1, true))
  truthy(not resolved:find("<<<<<<<", 1, true))
  equal("", git(root, { "diff", "--name-only", "--diff-filter=U" }).stdout)
end)

test("conflict markers must be exactly seven characters", function()
  local conflict = require("ngit.git.conflict")
  -- A heading underline in the incoming side is text, not a separator.
  local underline = {
    "<<<<<<< HEAD",
    "Ours title",
    "=======",
    "Theirs title",
    "==========",
    ">>>>>>> topic",
  }
  local blocks, ambiguous = conflict.parse_markers(underline)
  equal(1, #blocks)
  equal(0, #ambiguous)
  equal(3, blocks[1].middle)
  equal({ "Ours title" }, conflict.resolve_lines(underline, blocks, "ours"))
  equal({ "Theirs title", "==========" }, conflict.resolve_lines(underline, blocks, "theirs"))

  -- Longer markers are what git nests inside a recursive merge base.
  local nested = { "<<<<<<<<< inner", "x", "=========", "y", ">>>>>>>>> inner" }
  equal(0, #conflict.parse_markers(nested))

  -- Windows line endings keep the marker and drop the carriage return from the label.
  local crlf = conflict.parse_markers({
    "<<<<<<< HEAD\r",
    "a\r",
    "=======\r",
    "b\r",
    ">>>>>>> topic\r",
  })
  equal(1, #crlf)
  equal("HEAD", crlf[1].ours_label)
  equal("topic", crlf[1].theirs_label)
end)

test("a conflict block with two separators is ambiguous and never rewritten", function()
  local conflict = require("ngit.git.conflict")
  local lines = {
    "<<<<<<< HEAD",
    "ours",
    "=======",
    "theirs",
    "=======",
    "more theirs",
    ">>>>>>> topic",
    "<<<<<<< HEAD",
    "ours two",
    "||||||| base",
    "base two",
    "=======",
    "theirs two",
    "||||||| stray",
    ">>>>>>> topic",
  }
  local blocks, ambiguous = conflict.parse_markers(lines)
  equal(0, #blocks)
  equal({ { start = 1, finish = 7 }, { start = 8, finish = 15 } }, ambiguous)
  truthy(conflict.has_markers(lines))
  truthy(not conflict.has_markers({ "plain", "==========", "text" }))
end)

test("an ambiguous conflict is refused and the file stays unmerged", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "notes.txt"), "title\n")
  git(root, { "add", "notes.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  git(root, { "switch", "-q", "-c", "topic" })
  write_file(vim.fs.joinpath(root, "notes.txt"), "theirs\n=======\nmore\n")
  git(root, { "commit", "-q", "-am", "topic" })
  git(root, { "switch", "-q", "main" })
  write_file(vim.fs.joinpath(root, "notes.txt"), "ours\n")
  git(root, { "commit", "-q", "-am", "main" })
  git(root, { "merge", "-q", "topic" }, { accept = { [1] = true } })

  local conflict = require("ngit.git.conflict")
  local before = read_file(vim.fs.joinpath(root, "notes.txt"))
  local ok, err = wait_for(function(done)
    conflict.resolve(root, "notes.txt", "theirs", 2, done)
  end)
  equal(false, ok)
  truthy(err and err:find("more than one separator", 1, true), err)
  ok, err = wait_for(function(done)
    conflict.choose(root, "notes.txt", "both", done)
  end)
  equal(false, ok)
  equal(before, read_file(vim.fs.joinpath(root, "notes.txt")))
  equal("notes.txt\n", git(root, { "diff", "--name-only", "--diff-filter=U" }).stdout)
end)

test("a revision range lists its files and diffs each of them", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "kept.txt"), "base\n")
  git(root, { "add", "kept.txt" })
  git(root, { "commit", "-q", "-m", "base" })

  git(root, { "switch", "-q", "-c", "feature" })
  write_file(vim.fs.joinpath(root, "kept.txt"), "changed\n")
  write_file(vim.fs.joinpath(root, "added.txt"), "new\n")
  git(root, { "add", "." })
  git(root, { "commit", "-q", "-m", "feature work" })
  -- A change on the base that the range must not report.
  git(root, { "switch", "-q", "main" })
  write_file(vim.fs.joinpath(root, "elsewhere.txt"), "unrelated\n")
  git(root, { "add", "elsewhere.txt" })
  git(root, { "commit", "-q", "-m", "unrelated" })
  git(root, { "switch", "-q", "feature" })

  local range = require("ngit.git.range")
  local files, err = wait_for(function(done)
    range.files(root, "main...HEAD", done)
  end)
  equal(nil, err)
  local by_path = {}
  for _, file in ipairs(files) do
    by_path[file.path] = file
  end
  equal(2, #files)
  equal("modified", by_path["kept.txt"].kind)
  equal("added", by_path["added.txt"].kind)
  truthy(by_path["elsewhere.txt"] == nil, "the three-dot range reported a change made on the base")

  local diff = wait_for(function(done)
    range.diff(root, "main...HEAD", "kept.txt", 3, 10000, done)
  end)
  truthy(diff.text:find("+changed", 1, true))

  local spec, spec_err = wait_for(function(done)
    range.review_spec(root, done)
  end)
  -- Without an upstream or an origin, the default branch is the base.
  equal(nil, spec_err)
  equal("main...HEAD", spec)

  local valid = wait_for(function(done)
    range.validate(root, "main...HEAD", done)
  end)
  equal(true, valid)
  local invalid = wait_for(function(done)
    range.validate(root, "no-such-ref...HEAD", done)
  end)
  equal(false, invalid)
end)

test("name-status parsing keeps rename pairs and their scores apart", function()
  local range = require("ngit.git.range")
  local files = range.parse(
    table.concat(
      { "M", "kept.txt", "R100", "old name.txt", "new name.txt", "A", "added.txt" },
      "\0"
    ) .. "\0"
  )
  equal(3, #files)
  equal("modified", files[1].kind)
  equal("renamed", files[2].kind)
  equal("old name.txt", files[2].old_path)
  equal("new name.txt", files[2].path)
  equal("added.txt", files[3].path)
end)

test("blame annotates a real file and reports one header per commit", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "blamed.txt"), "first\nsecond\n")
  git(root, { "add", "blamed.txt" })
  git(root, { "commit", "-q", "-m", "first commit" })
  local first = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)
  write_file(vim.fs.joinpath(root, "blamed.txt"), "first\nsecond\nthird\n")
  git(root, { "commit", "-q", "-am", "second commit" })
  local second = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)

  local blame = require("ngit.git.blame")
  local lines, commits, err = wait_for(function(done)
    blame.load(root, "blamed.txt", {}, done)
  end)
  equal(nil, err)
  equal(3, #lines)
  equal(first, lines[1].oid)
  equal(second, lines[3].oid)
  equal("first", lines[1].text)
  equal("ngit tests", commits[first].author)
  equal("second commit", commits[second].summary)
  truthy(commits[first].timestamp > 0)
end)

test("worktree and submodule listings parse their porcelain forms", function()
  local worktree = require("ngit.git.worktree")
  local parsed = worktree.parse(table.concat({
    "worktree /repo",
    "HEAD abc",
    "branch refs/heads/main",
    "",
    "worktree /repo/feature",
    "HEAD def",
    "detached",
    "locked",
    "",
  }, "\n"))
  equal(2, #parsed)
  equal("/repo", parsed[1].path)
  equal("main", parsed[1].branch)
  equal(true, parsed[2].detached)
  equal(true, parsed[2].locked)

  local submodule = require("ngit.git.submodule")
  local modules = submodule.parse(table.concat({
    " 1111111111111111111111111111111111111111 vendor/one (v1.0)",
    "+2222222222222222222222222222222222222222 vendor/two (heads/main)",
    "-3333333333333333333333333333333333333333 vendor/three",
  }, "\n"))
  equal(3, #modules)
  equal("current", modules[1].state)
  equal("vendor/one", modules[1].path)
  equal("v1.0", modules[1].describe)
  equal("modified", modules[2].state)
  equal("uninitialized", modules[3].state)

  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "initial" })
  local live, err = wait_for(function(done)
    worktree.list(root, done)
  end)
  equal(nil, err)
  equal(1, #live)
  -- Git reports the resolved path, and a temporary directory on macOS reaches it
  -- through a symlink, so the comparison has to resolve too.
  equal(vim.uv.fs_realpath(root), vim.uv.fs_realpath(live[1].path))
end)

test("commit history accepts server-side filters and follows one path", function()
  local log = require("ngit.git.log")
  equal(nil, log.parse_query("plain substring"))
  equal({ author = "ada" }, log.parse_query("author:ada"))
  equal({ grep = "fix crash", path = "lua/" }, log.parse_query('grep:"fix crash" path:lua/'))
  equal({ since = "2.weeks", all = true }, log.parse_query("since:2.weeks all:true"))

  local root = repository()
  write_file(vim.fs.joinpath(root, "followed.txt"), "one\n")
  git(root, { "add", "followed.txt" })
  git(root, { "commit", "-q", "-m", "add followed" })
  write_file(vim.fs.joinpath(root, "other.txt"), "one\n")
  git(root, { "add", "other.txt" })
  git(root, { "commit", "-q", "-m", "add other" })
  assert(
    vim.uv.fs_rename(vim.fs.joinpath(root, "followed.txt"), vim.fs.joinpath(root, "renamed.txt"))
  )
  git(root, { "add", "-A" })
  git(root, { "commit", "-q", "-m", "rename followed" })

  local matched = wait_for(function(done)
    log.list(root, { limit = 10, query = { grep = "add other" } }, done)
  end)
  equal(1, #matched)
  equal("add other", matched[1].subject)

  -- --follow is what makes the pre-rename history visible under the new name.
  local followed = wait_for(function(done)
    log.list(root, { limit = 10, path = "renamed.txt", follow = true }, done)
  end)
  equal(2, #followed)
  equal("rename followed", followed[1].subject)
  equal("add followed", followed[2].subject)

  local narrowed = wait_for(function(done)
    log.show(root, matched[1].oid, 10000, done, "other.txt")
  end)
  truthy(narrowed.text:find("other.txt", 1, true))
end)

test("remote URLs become browsable links only when the shape is unambiguous", function()
  local remote = require("ngit.git.remote")
  equal("https://github.com/owner/repo", remote.browse_url("git@github.com:owner/repo.git"))
  equal("https://gitlab.com/group/sub/repo", remote.browse_url("git@gitlab.com:group/sub/repo"))
  equal(
    "https://github.com/owner/repo",
    remote.browse_url("ssh://git@github.com:22/owner/repo.git")
  )
  equal("https://github.com/owner/repo", remote.browse_url("https://github.com/owner/repo.git"))
  equal(nil, remote.browse_url("/srv/git/repo.git"))
  equal(nil, remote.browse_url(""))

  local root = repository()
  git(root, { "commit", "-q", "--allow-empty", "-m", "initial" })
  git(root, { "remote", "add", "origin", "git@github.com:owner/repo.git" })
  local remotes, err = wait_for(function(done)
    remote.list(root, done)
  end)
  equal(nil, err)
  equal(1, #remotes)
  equal("origin", remotes[1].name)
  equal("git@github.com:owner/repo.git", remotes[1].fetch_url)
end)

test("ignoring whitespace demotes the row and disables hunk actions", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "spaced.txt"), "value = 1\nkeep = 2\n")
  git(root, { "add", "spaced.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "spaced.txt"), "value   =   1\nkeep = 22\n")

  local diff_backend = require("ngit.git.diff")
  local plain = wait_for(function(done)
    diff_backend.load(root, "unstaged", "spaced.txt", 3, 10000, done)
  end)
  truthy(plain.text:find("+value   =   1", 1, true))

  local ignored = wait_for(function(done)
    diff_backend.load(root, "unstaged", "spaced.txt", 3, 10000, done, { ignore_whitespace = true })
  end)
  -- The row does not disappear, it is demoted to context — printed in its new,
  -- collapsed form. That is exactly why the patch cannot be applied: the context
  -- text is not what the index holds.
  truthy(ignored.text:find("\n value   =   1", 1, true), "the row was not demoted to context")
  truthy(not ignored.text:find("+value", 1, true), "the whitespace-only change was still a change")
  truthy(not ignored.text:find("-value", 1, true), "the whitespace-only change was still a change")
  truthy(ignored.text:find("+keep = 22", 1, true), "the real change was hidden")

  local patch = assert(diff_backend.patch_at_hunk(ignored.lines, ignored.hunks[1]))
  local applied = wait_for(function(done)
    require("ngit.git.mutate").apply(root, patch, { target = "index" }, done)
  end)
  equal(false, applied, "git accepted a patch built from a collapsed context line")

  -- So the session refuses the hunk rather than handing git something it cannot
  -- place, while the whole file still stages.
  require("ngit").setup({ ignore_whitespace = true })
  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.current_diff ~= nil
  end, 10))
  local session = require("ngit")._active_session()
  session.dashboard:focus_preview()
  local refused, reason = session:selection_patch(false)
  equal(nil, refused)
  truthy(reason and reason:find("whitespace", 1, true), "the refusal did not say why")

  session:focus_panel("status")
  session:stage()
  truthy(
    vim.wait(10000, function()
      return git(root, { "diff", "--cached", "--name-only" }).stdout:find("spaced.txt", 1, true)
        ~= nil
    end, 10),
    "the whole file did not stage while whitespace was ignored"
  )
  require("ngit").close()
  require("ngit").setup()
end)

test("commit switches reach git and the editor names them", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "signed.txt"), "one\n")
  git(root, { "add", "signed.txt" })
  local ok, err = wait_for(function(done)
    require("ngit.git.mutate").commit(root, "signed commit", { signoff = true }, done)
  end)
  equal(true, ok, err)
  truthy(git(root, { "log", "-1", "--format=%B" }).stdout:find("Signed-off-by:", 1, true))

  local CommitEditor = require("ngit.ui.commit_editor")
  local editor = CommitEditor.new(root, {
    amend = false,
    staged = 1,
    branch = "main",
    commit_options = { signoff = true, no_verify = true },
    on_complete = function() end,
  })
  local title = editor:title()
  truthy(title:find("--signoff", 1, true), "the title hid a switch that changes the commit")
  truthy(title:find("--no-verify", 1, true))
  editor:close()
end)

test("commit menu switches reach git through the session", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "base.txt"), "base\n")
  git(root, { "add", "base.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  -- A hook that always refuses, so only --no-verify can get a commit through.
  local hook = vim.fs.joinpath(root, ".git", "hooks", "pre-commit")
  write_file(hook, "#!/bin/sh\nexit 1\n")
  vim.uv.fs_chmod(hook, 493)
  write_file(vim.fs.joinpath(root, "hooked.txt"), "one\n")
  git(root, { "add", "hooked.txt" })

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status ~= nil
  end, 10))
  local session = require("ngit")._active_session()

  local original_select = vim.ui.select
  local function pick(prefix)
    vim.ui.select = function(items, _, on_choice)
      for index, item in ipairs(items) do
        if vim.startswith(item, prefix) then
          on_choice(item, index)
          return
        end
      end
      on_choice(nil, nil)
    end
  end
  local function submit(message)
    truthy(vim.wait(10000, function()
      return session.commit_editor ~= nil and not session.commit_editor.closed
    end, 10), "the commit editor did not open")
    local editor = session.commit_editor
    vim.api.nvim_buf_set_lines(editor.buffer, 0, -1, false, { message })
    editor:submit()
    -- The editor closes from the commit's own callback, which can run after git
    -- has already written the commit; the next menu pick must not find it open.
    truthy(vim.wait(10000, function()
      return session.commit_editor == nil
    end, 10), ("%q never finished committing"):format(message))
    equal(message .. "\n", git(root, { "log", "-1", "--format=%s" }).stdout)
  end

  pick("Commit with --no-verify")
  session:commit_menu()
  truthy(session.commit_editor and session.commit_editor.commit_options.no_verify)
  submit("skip the hook")

  -- Nothing is staged now; --allow-empty must still open the editor, and the menu
  -- is reachable from a panel other than Changes.
  vim.uv.fs_unlink(hook)
  session:switch_view("commits")
  pick("Commit --allow-empty")
  session:commit_menu()
  submit("empty on purpose")
  equal("", git(root, { "show", "--name-only", "--format=", "HEAD" }).stdout)

  vim.ui.select = original_select
  require("ngit").close()
end)

test("review mode lists a range and refuses to stage from it", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "reviewed.txt"), "base\n")
  git(root, { "add", "reviewed.txt" })
  git(root, { "commit", "-q", "-m", "base" })
  git(root, { "switch", "-q", "-c", "feature" })
  write_file(vim.fs.joinpath(root, "reviewed.txt"), "changed\n")
  git(root, { "commit", "-q", "-am", "feature" })
  -- An unstaged working-tree change, so leaving review mode is observable.
  write_file(vim.fs.joinpath(root, "reviewed.txt"), "changed again\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status ~= nil
  end, 10))
  local session = require("ngit")._active_session()

  session:set_range("main...HEAD")
  truthy(
    vim.wait(10000, function()
      return session.range_files ~= nil and #session.panels.status.entries == 1
    end, 10),
    "the range file list never arrived"
  )
  equal("range", session.panels.status.entries[1].section)
  equal("reviewed.txt", session.panels.status.entries[1].file.path)
  truthy(session.dashboard.panels.status.detail:find("review main...HEAD", 1, true))

  -- Staging has no meaning against a commit-to-commit range, so it is refused
  -- rather than passed to git.
  local staged_before = git(root, { "diff", "--cached", "--name-only" }).stdout
  session:stage()
  equal(staged_before, git(root, { "diff", "--cached", "--name-only" }).stdout)

  session:set_range(nil)
  truthy(
    vim.wait(10000, function()
      return session.range == nil
        and #session.panels.status.entries == 1
        and session.panels.status.entries[1].section == "unstaged"
    end, 10),
    "leaving review mode did not restore the working tree list"
  )
  require("ngit").close()
end)

test("following one file narrows the Commits panel to its history", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "tracked.txt"), "one\n")
  git(root, { "add", "tracked.txt" })
  git(root, { "commit", "-q", "-m", "touch tracked" })
  write_file(vim.fs.joinpath(root, "unrelated.txt"), "one\n")
  git(root, { "add", "unrelated.txt" })
  git(root, { "commit", "-q", "-m", "touch unrelated" })

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and #(session.panels.commits.data or {}) == 2
  end, 10))
  local session = require("ngit")._active_session()

  session:set_history("tracked.txt")
  truthy(
    vim.wait(10000, function()
      return #(session.panels.commits.data or {}) == 1
    end, 10),
    "the history filter never narrowed the panel"
  )
  equal("touch tracked", session.panels.commits.data[1].subject)

  session:set_history(nil)
  truthy(vim.wait(10000, function()
    return #(session.panels.commits.data or {}) == 2
  end, 10))
  require("ngit").close()
end)

test("diff options are part of the preview cache key", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "options.txt"), "one\n")
  git(root, { "add", "options.txt" })
  git(root, { "commit", "-q", "-m", "initial" })
  write_file(vim.fs.joinpath(root, "options.txt"), "two\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.current_diff ~= nil
  end, 10))
  local session = require("ngit")._active_session()
  local entry = session.panels.status.entries[1]
  local before = session:cache_key(entry)

  session:toggle_whitespace()
  truthy(session.config.ignore_whitespace)
  truthy(session:cache_key(entry) ~= before, "ignoring whitespace reused the previous preview")

  session:adjust_context(3)
  equal(6, session.config.context)
  truthy(session:cache_key(entry):find("6w", 1, true), "the context width is not in the key")

  session:toggle_whitespace()
  equal(false, session.config.ignore_whitespace)
  require("ngit").close()
end)

test("blame rows carry their commit and open it in the Commits panel", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "opened.txt"), "one\ntwo\n")
  git(root, { "add", "opened.txt" })
  git(root, { "commit", "-q", "-m", "first" })
  write_file(vim.fs.joinpath(root, "opened.txt"), "one\ntwo\nthree\n")
  git(root, { "commit", "-q", "-am", "second" })
  local head = vim.trim(git(root, { "rev-parse", "HEAD" }).stdout)

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and #(session.panels.commits.data or {}) == 2
  end, 10))
  local session = require("ngit")._active_session()

  session:blame_path("opened.txt", 3)
  truthy(
    vim.wait(10000, function()
      return session.blame_view ~= nil and not session.blame_view.closed
    end, 10),
    "the blame view never opened"
  )
  local view = session.blame_view
  local lines = vim.api.nvim_buf_get_lines(view.buffer, 0, -1, false)
  equal(3, #lines)
  truthy(lines[1]:find("ngit tests", 1, true), "the author column is missing")
  truthy(lines[3]:find(head:sub(1, 8), 1, true), "the newest row names the wrong commit")
  -- A run of lines from one commit annotates only its first row.
  truthy(lines[2]:find("^%s+│"), "a repeated commit annotated every row")

  vim.api.nvim_set_current_win(view.window)
  vim.api.nvim_win_set_cursor(view.window, { 3, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
  truthy(
    vim.wait(10000, function()
      local entry = session.panels.commits.entries[session.panels.commits.selected]
      return session.active_panel == "commits" and entry and entry.commit.oid == head
    end, 10),
    "pressing <CR> in blame did not reveal the commit"
  )
  require("ngit").close()
end)

test("the rebase plan editor cycles actions, reorders, and refuses an empty plan", function()
  local RebaseEditor = require("ngit.ui.rebase_editor")
  local submitted
  local editor = RebaseEditor.new({
    base = "HEAD~2",
    label = "HEAD~2",
    steps = {
      { action = "pick", oid = string.rep("a", 40), subject = "first" },
      { action = "pick", oid = string.rep("b", 40), subject = "second" },
    },
    on_submit = function(plan)
      submitted = plan
    end,
    on_close = function() end,
  })

  local lines = vim.api.nvim_buf_get_lines(editor.buffer, 0, -1, false)
  equal(2, #lines)
  truthy(lines[1]:find("pick", 1, true))

  -- Squashing the first commit has nothing before it to fold into.
  vim.api.nvim_win_set_cursor(editor.window, { 1, 0 })
  editor:set_action("squash")
  equal("pick", editor.steps[1].action)

  vim.api.nvim_win_set_cursor(editor.window, { 2, 0 })
  editor:set_action("squash")
  equal("squash", editor.steps[2].action)
  editor:move(-1)
  equal("second", editor.steps[1].subject)
  equal(1, vim.api.nvim_win_get_cursor(editor.window)[1])

  editor.steps[1].action = "drop"
  editor.steps[2].action = "drop"
  editor:submit()
  equal(nil, submitted)

  editor.steps[1].action = "pick"
  editor:submit()
  truthy(submitted, "a valid plan was not submitted")
  equal(true, editor.closed)
end)

test("every menu builds its choices against a real repository", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "menu.txt"), "one\n")
  git(root, { "add", "menu.txt" })
  git(root, { "commit", "-q", "-m", "first commit" })
  git(root, { "remote", "add", "origin", "git@github.com:owner/repo.git" })
  git(root, { "branch", "topic" })
  write_file(vim.fs.joinpath(root, "menu.txt"), "two\n")
  git(root, { "stash", "push", "-q", "-m", "a stash" })
  write_file(vim.fs.joinpath(root, "menu.txt"), "three\n")
  write_file(vim.fs.joinpath(root, "fresh.txt"), "new\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session
      and session.status ~= nil
      and #(session.panels.commits.data or {}) > 0
      and #(session.panels.stashes.data or {}) > 0
  end, 10))
  local session = require("ngit")._active_session()

  -- Both pickers are answered with a cancel, so the menus are built and torn down
  -- without anything being run against the repository.
  local prompts = {}
  local original_select, original_input = vim.ui.select, vim.ui.input
  vim.ui.select = function(items, opts, on_choice)
    prompts[#prompts + 1] = { prompt = (opts or {}).prompt or "", items = items }
    on_choice(nil, nil)
  end
  vim.ui.input = function(opts, on_confirm)
    prompts[#prompts + 1] = { prompt = (opts or {}).prompt or "", items = {} }
    on_confirm(nil)
  end

  local function invoke(panel, method, expected)
    local before = #prompts
    session:focus_panel(panel)
    session[method](session)
    truthy(
      vim.wait(5000, function()
        return #prompts > before
      end, 10),
      ("%s offered no choices"):format(method)
    )
    local last = prompts[#prompts]
    truthy(
      last.prompt:find(expected, 1, true),
      ("%s prompted %q, expected %q"):format(method, last.prompt, expected)
    )
    return last
  end

  local ok, err = pcall(function()
    invoke("status", "commit_menu", "Commit")
    invoke("status", "stash_menu", "Stash")
    invoke("status", "file_menu", "menu.txt")
    invoke("status", "review", "Review")
    invoke("status", "file_history", "History")
    invoke("status", "remote_menu", "Remote")
    invoke("status", "repos_menu", "Worktrees and submodules")

    local reset = invoke("commits", "reset", "Reset onto")
    equal(4, #reset.items)
    truthy(reset.items[1]:find("Cancel", 1, true), "Cancel is not the first choice")
    truthy(reset.items[4]:find("--hard", 1, true), "the destructive mode is missing")

    invoke("commits", "revert", "Revert")
    invoke("commits", "checkout_commit", "detached HEAD")
    invoke("commits", "tag", "Tag name for")
    invoke("commits", "interactive_rebase", "Interactive rebase")
    local copy = invoke("commits", "copy_menu", "Copy")
    truthy(#copy.items >= 5, "the commit copy menu is missing entries")

    invoke("branches", "set_upstream", "Upstream for")
    invoke("branches", "rename_item", "Rename")
    invoke("stashes", "delete_item", "Drop")

    -- The way back out of review mode only makes sense once there is one.
    local before_range = invoke("status", "review", "Review")
    for _, label in ipairs(before_range.items) do
      truthy(
        not label:find("Back to the working tree", 1, true),
        "review offered a way out before there was a range"
      )
    end
    session.range = { spec = "main...HEAD" }
    local during_range = invoke("status", "review", "Review")
    local offers_exit = false
    for _, label in ipairs(during_range.items) do
      offers_exit = offers_exit or label:find("Back to the working tree", 1, true) ~= nil
    end
    truthy(offers_exit, "review offered no way back to the working tree")
    session.range = nil
  end)

  vim.ui.select, vim.ui.input = original_select, original_input
  require("ngit").close()
  truthy(ok, tostring(err))
end)

test("footer actions stay a single row while the key sheet lists everything", function()
  local mappings = require("ngit.config").defaults().mappings
  local actions = require("ngit.ui.actions")
  local footer = actions.for_context({
    panel = "commits",
    entry = { kind = "commit", commit = { oid = "abc", subject = "x" } },
    has_more = false,
  }, mappings)
  local ids = {}
  for _, item in ipairs(footer) do
    ids[item.id] = true
  end
  truthy(ids.revert, "revert is common enough to belong in the footer")
  truthy(not ids.copy_menu, "menu actions must not crowd the footer")
  truthy(not ids.blame, "menu actions must not crowd the footer")

  -- Hidden actions still have to be discoverable, so they are in the key sheet.
  local sheet = table.concat(require("ngit.ui.help").lines(mappings), "\n")
  for _, label in ipairs({
    "Blame the selected file",
    "Review a revision range",
    "Interactive rebase plan",
    "Remote options",
    "Copy hash, path, or patch",
    "Worktrees and submodules",
  }) do
    truthy(sheet:find(label, 1, true), ("the key sheet omits %q"):format(label))
  end
end)

test("every action a panel offers is reachable from its own mapping", function()
  local mappings = require("ngit.config").defaults().mappings
  local Session = require("ngit.ui.session")
  for _, action in ipairs(require("ngit.ui.actions").definitions()) do
    truthy(
      mappings[action.mapping] ~= nil,
      ("action %q references unknown mapping %q"):format(action.id, action.mapping)
    )
    truthy(
      type(Session[action.method]) == "function",
      ("action %q has no session method %q"):format(action.id, action.method)
    )
  end
end)

io.stdout:write(("\n%d passed, %d failed\n"):format(passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
