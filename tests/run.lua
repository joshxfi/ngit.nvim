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

local function git(root, args, opts)
  opts = opts or {}
  local command = { "git", "-c", "user.name=ngit tests", "-c", "user.email=ngit@example.test" }
  vim.list_extend(command, args)
  local result = vim.system(command, {
    cwd = root,
    text = true,
    stdin = opts.stdin,
  }):wait(10000)
  if not opts.accept or not opts.accept[result.code] then
    equal(0, result.code, table.concat(command, " ") .. "\n" .. (result.stderr or ""))
  end
  return result
end

local function repository()
  local root = vim.fn.tempname()
  assert(vim.uv.fs_mkdir(root, 448))
  git(root, { "init", "-q", "-b", "main" })
  return root
end

local function wait_for(register)
  local complete = false
  local values
  register(function(...)
    values = { ... }
    complete = true
  end)
  truthy(vim.wait(10000, function()
    return complete
  end, 10), "asynchronous operation timed out")
  return unpack(values)
end

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
  assert(vim.uv.fs_rename(
    vim.fs.joinpath(root, "old name.txt"),
    vim.fs.joinpath(root, "new name.txt")
  ))
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

test("session renders a real repository and closes cleanly", function()
  local root = repository()
  write_file(vim.fs.joinpath(root, "visible.txt"), "hello\n")

  require("ngit").open({ cwd = root })
  truthy(vim.wait(10000, function()
    local session = require("ngit")._active_session()
    return session and session.status and #session.entries == 1 and session.current_diff ~= nil
  end, 10), "session did not finish rendering")

  local session = require("ngit")._active_session()
  local file_lines = vim.api.nvim_buf_get_lines(session.files_buf, 0, -1, false)
  truthy(table.concat(file_lines, "\n"):find("visible.txt", 1, true))
  local preview = vim.api.nvim_buf_get_lines(session.preview_buf, 0, -1, false)
  truthy(table.concat(preview, "\n"):find("+hello", 1, true))
  require("ngit").close()
  equal(nil, require("ngit")._active_session())
end)

io.stdout:write(("\n%d passed, %d failed\n"):format(passed, #failures))
if #failures > 0 then
  vim.cmd("cquit 1")
end
vim.cmd("qa!")
