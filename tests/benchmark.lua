local status = require("ngit.git.status")

local records = {
  "# branch.oid abcdef",
  "# branch.head benchmark",
  "# branch.ab +12 -3",
}
for index = 1, 10000 do
  records[#records + 1] = ("1 .M N... 100644 100644 100644 abc def src/file-%05d.lua"):format(index)
end
records[#records + 1] = ""
local fixture = table.concat(records, "\0")

for _ = 1, 5 do
  status.parse(fixture)
end

local started = vim.uv.hrtime()
for _ = 1, 50 do
  local parsed = status.parse(fixture)
  assert(#parsed.files == 10000)
end
local elapsed_ms = (vim.uv.hrtime() - started) / 1e6

print(("porcelain parser: %.2f ms/run (10,000 files)"):format(elapsed_ms / 50))

local commit_records = {}
for index = 1, 10000 do
  commit_records[#commit_records + 1] = table.concat({
    string.char(30) .. ("%040d"):format(index),
    "",
    "Author",
    "author@example.test",
    tostring(1700000000 + index),
    "",
    ("commit %d"):format(index),
    "",
  }, "\0")
end
local commit_fixture = table.concat(commit_records, "\n")
local commit_started = vim.uv.hrtime()
for _ = 1, 20 do
  assert(#require("ngit.git.log").parse(commit_fixture) == 10000)
end
local commit_ms = (vim.uv.hrtime() - commit_started) / 1e6
print(("commit parser: %.2f ms/run (10,000 commits)"):format(commit_ms / 20))

local branch_records = {}
for index = 1, 10000 do
  branch_records[#branch_records + 1] = table.concat({
    string.char(30) .. ("refs/heads/branch-%d"):format(index),
    ("branch-%d"):format(index),
    ("%040d"):format(index),
    "",
    "",
    tostring(1700000000 + index),
    "branch tip",
    index == 1 and "*" or " ",
    "",
  }, "\0")
end
local branch_fixture = table.concat(branch_records, "\n")
local branch_started = vim.uv.hrtime()
for _ = 1, 20 do
  assert(#require("ngit.git.branch").parse(branch_fixture) == 10000)
end
local branch_ms = (vim.uv.hrtime() - branch_started) / 1e6
print(("branch parser: %.2f ms/run (10,000 refs)"):format(branch_ms / 20))

local repeated = string.rep("a", 3998)
local diff_fixture = table.concat({
  "diff --git a/long.lua b/long.lua",
  "--- a/long.lua",
  "+++ b/long.lua",
  "@@ -1 +1 @@",
  "-" .. repeated .. "x",
  "+" .. repeated .. "y",
  "",
}, "\n")
local parsed_diff = require("ngit.git.diff").parse(diff_fixture, #diff_fixture + 1)
local diff_view = require("ngit.ui.diff_view")
local diff_started = vim.uv.hrtime()
for _ = 1, 500 do
  local split = diff_view.split(parsed_diff, { title = "long line" })
  assert(#split.left.lines > 0)
  assert(#diff_view.unified(parsed_diff, { title = "long line" }, split).unified.lines > 0)
end
local diff_ms = (vim.uv.hrtime() - diff_started) / 1e6
print(("diff presentation: %.3f ms/run (4 KiB near-identical lines)"):format(diff_ms / 500))

vim.cmd("qa!")
