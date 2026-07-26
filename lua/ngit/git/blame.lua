local runner = require("ngit.git.runner")

local M = {}

M.uncommitted = string.rep("0", 40)

---@class NgitBlameCommit
---@field oid string
---@field author string
---@field timestamp integer
---@field summary string

---@class NgitBlameLine
---@field oid string
---@field number integer Line number in the blamed revision of the file.
---@field text string

--- Parses `git blame --porcelain`.
---
--- The porcelain form repeats a commit's header only the first time it appears,
--- which is why the commits are collected into a table of their own rather than
--- copied onto every line: a file with one author would otherwise carry the same
--- name thousands of times.
---@param output string
---@return NgitBlameLine[] lines, table<string, NgitBlameCommit> commits
function M.parse(output)
  local lines, commits = {}, {}
  local current
  for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
    if line:sub(1, 1) == "\t" then
      if current then
        lines[#lines + 1] = { oid = current.oid, number = current.number, text = line:sub(2) }
        current = nil
      end
    elseif not current then
      local oid, number = line:match("^(%x+) %d+ (%d+)")
      if oid then
        current = { oid = oid, number = tonumber(number) }
        commits[oid] = commits[oid] or { oid = oid, author = "", timestamp = 0, summary = "" }
      end
    else
      local commit = commits[current.oid]
      local key, value = line:match("^(%S+) (.*)$")
      if key == "author" then
        commit.author = value
      elseif key == "author-time" then
        commit.timestamp = tonumber(value) or 0
      elseif key == "summary" then
        commit.summary = value
      end
    end
  end
  return lines, commits
end

--- `-w` ignores whitespace-only changes so a reindent does not claim every line,
--- and the rename detection follows content across moves within the file.
---@param root string
---@param path string
---@param opts? { revision?: string, max_bytes?: integer }
---@param callback fun(lines: NgitBlameLine[]?, commits: table<string, NgitBlameCommit>?, err: string?)
function M.load(root, path, opts, callback)
  opts = opts or {}
  local args = { "blame", "--porcelain", "-w", "-M" }
  if opts.revision and opts.revision ~= "" then
    args[#args + 1] = opts.revision
  end
  args[#args + 1] = "--"
  args[#args + 1] = path
  return runner.run(args, {
    cwd = root,
    max_stdout_bytes = opts.max_bytes,
  }, function(result)
    if not runner.ok(result) then
      callback(nil, nil, runner.error_message(result))
      return
    end
    local lines, commits = M.parse(result.stdout)
    callback(lines, commits, nil)
  end)
end

return M
