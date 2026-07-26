local diff_parser = require("ngit.git.diff")
local records = require("ngit.git.records")
local runner = require("ngit.git.runner")

local M = {}

local format = table.concat({
  "%x1e%H",
  "%P",
  "%an",
  "%ae",
  "%at",
  "%D",
  "%s",
  "",
}, "%x00")

---@class NgitCommit
---@field oid string
---@field parents string[]
---@field author string
---@field email string
---@field timestamp integer
---@field decorations string
---@field subject string

---@param output string
---@return NgitCommit[]
function M.parse(output)
  local commits = {}
  for _, fields in ipairs(records.control_records(output)) do
    if #fields >= 7 then
      commits[#commits + 1] = {
        oid = fields[1],
        parents = vim.split(fields[2], " ", { plain = true, trimempty = true }),
        author = fields[3],
        email = fields[4],
        timestamp = tonumber(fields[5]) or 0,
        decorations = fields[6],
        subject = fields[7],
      }
    end
  end
  return commits
end

---@class NgitLogQuery
---@field author? string
---@field grep? string
---@field since? string
---@field until_? string
---@field path? string
---@field all? boolean Include every ref rather than the current branch only.

--- Recognised prefixes for the Commits filter. A query naming one of these is
--- answered by git over the whole history; anything else stays a substring match
--- against the rows already loaded, which is instant and needs no subprocess.
local query_prefixes = {
  author = "author",
  grep = "grep",
  message = "grep",
  path = "path",
  file = "path",
  since = "since",
  after = "since",
  ["until"] = "until_",
  before = "until_",
}

--- Parses `author:ada grep:"fix crash" path:lua/` into a query table. Returns nil
--- when nothing in the text names a field, which is what tells the caller to keep
--- filtering locally.
---@param text string?
---@return NgitLogQuery?
function M.parse_query(text)
  if not text or text == "" then
    return nil
  end
  local query, matched = {}, false
  -- Values may be quoted, so a plain split on whitespace is not enough.
  for key, value in text:gmatch('(%a+):"([^"]*)"') do
    local field = query_prefixes[key:lower()]
    if field then
      query[field] = value
      matched = true
    end
  end
  local stripped = text:gsub('%a+:"[^"]*"', " ")
  for key, value in stripped:gmatch("(%a+):(%S+)") do
    local field = query_prefixes[key:lower()]
    if field then
      query[field] = value
      matched = true
    end
  end
  if stripped:lower():find("all:true", 1, true) then
    query.all = true
    matched = true
  end
  if not matched then
    return nil
  end
  return query
end

---@param root string
---@param opts? { limit?: integer, skip?: integer, revision?: string, query?: NgitLogQuery, path?: string, follow?: boolean }
---@param callback fun(commits: NgitCommit[]?, has_more: boolean?, err: string?)
function M.list(root, opts, callback)
  opts = opts or {}
  local limit = opts.limit or 150
  local args = {
    "log",
    "--no-color",
    "--date-order",
    ("--max-count=%d"):format(limit + 1),
    ("--skip=%d"):format(opts.skip or 0),
    "--decorate=full",
    "--pretty=format:" .. format,
  }

  local query = opts.query or {}
  if query.author then
    args[#args + 1] = "--author=" .. query.author
  end
  if query.grep then
    args[#args + 1] = "--grep=" .. query.grep
    args[#args + 1] = "--regexp-ignore-case"
  end
  if query.since then
    args[#args + 1] = "--since=" .. query.since
  end
  if query.until_ then
    args[#args + 1] = "--until=" .. query.until_
  end
  if query.all then
    args[#args + 1] = "--all"
  end
  if opts.revision then
    args[#args + 1] = opts.revision
  end

  local path = opts.path or query.path
  if path and path ~= "" then
    -- --follow only accepts a single path and has to come before it.
    if opts.follow then
      table.insert(args, #args + 1, "--follow")
    end
    args[#args + 1] = "--"
    args[#args + 1] = path
  end

  return runner.run(args, { cwd = root }, function(result)
    if not runner.ok(result) then
      local unborn = result.code == 128
        and (
          result.stderr:find("does not have any commits yet", 1, true)
          or result.stderr:find("unknown revision", 1, true)
        )
      if unborn then
        callback({}, false, nil)
        return
      end
      callback(nil, nil, runner.error_message(result))
      return
    end
    local commits = M.parse(result.stdout)
    local has_more = #commits > limit
    if has_more then
      table.remove(commits)
    end
    callback(commits, has_more, nil)
  end)
end

--- `path` narrows the shown patch to one file, which is what a file-history
--- preview needs so a large commit does not bury the file being followed.
---@param root string
---@param oid string
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
---@param path? string
function M.show(root, oid, max_bytes, callback, path)
  local args = {
    "show",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--stat",
    "--patch",
    -- "fuller" repeats the author as committer on all but rebased or amended
    -- commits, spending two of the preview's first lines to say nothing.
    "--format=medium",
    "--max-count=1",
    oid,
  }
  if path and path ~= "" then
    args[#args + 1] = "--"
    args[#args + 1] = path
  end
  return runner.run(args, { cwd = root, max_stdout_bytes = max_bytes }, function(result)
    if not result.truncated and not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(diff_parser.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

---@param root string
---@param oid string
---@param callback fun(message: string?, err: string?)
function M.message(root, oid, callback)
  return runner.run({ "log", "-1", "--format=%B", oid }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback((result.stdout:gsub("%s+$", "")), nil)
  end)
end

--- Resolves a revision to a full object name, so a menu can report what it is
--- about to act on rather than the expression the user typed.
---@param root string
---@param revision string
---@param callback fun(oid: string?, err: string?)
function M.resolve(root, revision, callback)
  return runner.run({ "rev-parse", "--verify", revision }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(vim.trim(result.stdout), nil)
  end)
end

---@param root string
---@param callback fun(message: string?, err: string?)
function M.head_message(root, callback)
  return runner.run({ "log", "-1", "--format=%B" }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(result.stdout:gsub("%s+$", ""), nil)
  end)
end

return M
