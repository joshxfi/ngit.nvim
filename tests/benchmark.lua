local status = require("ngit.git.status")

local records = {
  "# branch.oid abcdef",
  "# branch.head benchmark",
  "# branch.ab +12 -3",
}
for index = 1, 10000 do
  records[#records + 1] =
    ("1 .M N... 100644 100644 100644 abc def src/file-%05d.lua"):format(index)
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
vim.cmd("qa!")

