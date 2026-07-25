local branch = require("ngit.git.branch")
local diff = require("ngit.git.diff")
local diff_view = require("ngit.ui.diff_view")
local log = require("ngit.git.log")
local status = require("ngit.git.status")

local sample_count = 7

local function output(message)
  vim.api.nvim_out_write(message .. "\n")
end

local function benchmark(label, iterations, warmups, run)
  for _ = 1, warmups do
    run()
  end

  local samples = {}
  for sample = 1, sample_count do
    collectgarbage("collect")
    local started = vim.uv.hrtime()
    for _ = 1, iterations do
      run()
    end
    samples[sample] = (vim.uv.hrtime() - started) / 1e6 / iterations
  end
  table.sort(samples)

  local median = samples[math.ceil(sample_count / 2)]
  output(
    ("%s: %.3f ms/run median (%.3f–%.3f, %d samples)"):format(
      label,
      median,
      samples[1],
      samples[#samples],
      sample_count
    )
  )
end

local version = vim.version()
output(
  ("environment: Neovim %d.%d.%d, %s/%s"):format(
    version.major,
    version.minor,
    version.patch,
    jit and jit.os or "unknown OS",
    jit and jit.arch or "unknown arch"
  )
)

local status_records = {
  "# branch.oid abcdef",
  "# branch.head benchmark",
  "# branch.ab +12 -3",
}
for index = 1, 10000 do
  status_records[#status_records + 1] = ("1 .M N... 100644 100644 100644 abc def src/file-%05d.lua"):format(
    index
  )
end
status_records[#status_records + 1] = ""
local status_fixture = table.concat(status_records, "\0")
benchmark("porcelain parser (10,000 files)", 10, 2, function()
  assert(#status.parse(status_fixture).files == 10000)
end)

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
benchmark("commit parser (10,000 commits)", 4, 1, function()
  assert(#log.parse(commit_fixture) == 10000)
end)

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
benchmark("branch parser (10,000 refs)", 4, 1, function()
  assert(#branch.parse(branch_fixture) == 10000)
end)

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
local parsed_diff = diff.parse(diff_fixture, #diff_fixture + 1)
benchmark("diff presentation (4 KiB near-identical lines)", 100, 2, function()
  local split = diff_view.split(parsed_diff, { title = "long line" })
  assert(#split.left.lines > 0)
  assert(#diff_view.unified(parsed_diff, { title = "long line" }, split).unified.lines > 0)
end)

vim.cmd("qa!")
