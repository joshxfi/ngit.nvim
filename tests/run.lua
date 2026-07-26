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
  local command = { "git", "-c", "user.name=ngit tests", "-c", "user.email=ngit@example.test" }
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
