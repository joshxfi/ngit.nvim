local M = {}

---@class NgitGitResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field command string[]
---@field truncated boolean

local function schedule(callback, value)
  vim.schedule(function()
    callback(value)
  end)
end

--- `--literal-pathspecs` is what keeps a file called `:(top)name.txt` from being
--- read as pathspec magic, so it is on for everything that takes a path from the
--- user.
---
--- A few porcelain commands build pathspecs of their own, though: `git stash push
--- --keep-index` runs an internal checkout against `:/`, and the literal flag
--- makes git reject its own argument. Those callers opt out and mark their paths
--- with the `:(literal)` prefix instead, which is the per-pathspec form of the
--- same guarantee.
local function command_for(args, literal_pathspecs)
  local command = { "git", "--no-pager" }
  if literal_pathspecs ~= false then
    command[#command + 1] = "--literal-pathspecs"
  end
  vim.list_extend(command, { "-c", "color.ui=false", "-c", "core.quotepath=false" })
  vim.list_extend(command, args)
  return command
end

function M.command(args)
  return command_for(args)
end

--- Marks a path so it survives without `--literal-pathspecs`.
---@param path string
---@return string
function M.literal(path)
  return ":(literal)" .. path
end

---@param args string[]
---@param opts? { cwd?: string, stdin?: string, readonly?: boolean, text?: boolean, max_stdout_bytes?: integer, env?: table<string, string>, literal_pathspecs?: boolean }
---@param callback fun(result: NgitGitResult)
---@return vim.SystemObj?
function M.run(args, opts, callback)
  opts = opts or {}
  local command = command_for(args, opts.literal_pathspecs)
  local env = { LC_ALL = "C", GIT_PAGER = "cat" }
  if opts.readonly ~= false then
    env.GIT_OPTIONAL_LOCKS = "0"
  end
  -- Editor overrides for the sequencer arrive this way. They are merged rather
  -- than replacing the base set so a caller cannot accidentally drop the C
  -- locale the parsers depend on.
  for name, value in pairs(opts.env or {}) do
    env[name] = value
  end

  local stdout_chunks = {}
  local stdout_bytes = 0
  local truncated = false
  local process
  local system_opts = {
    cwd = opts.cwd,
    env = env,
    stdin = opts.stdin,
    text = opts.text ~= false,
  }
  if opts.max_stdout_bytes then
    system_opts.stdout = function(err, data)
      if err or not data or truncated then
        return
      end
      local remaining = opts.max_stdout_bytes - stdout_bytes
      if #data <= remaining then
        stdout_chunks[#stdout_chunks + 1] = data
        stdout_bytes = stdout_bytes + #data
        return
      end
      if remaining > 0 then
        stdout_chunks[#stdout_chunks + 1] = data:sub(1, remaining)
      end
      truncated = true
      if process then
        pcall(process.kill, process, 15)
      end
    end
  end

  local ok
  ok, process = pcall(vim.system, command, system_opts, function(result)
    schedule(callback, {
      code = result.code,
      signal = result.signal,
      stdout = opts.max_stdout_bytes and table.concat(stdout_chunks) or (result.stdout or ""),
      stderr = result.stderr or "",
      command = command,
      truncated = truncated,
    })
  end)

  if not ok then
    schedule(callback, {
      code = 127,
      signal = 0,
      stdout = "",
      stderr = tostring(process),
      command = command,
      truncated = false,
    })
    return nil
  end
  return process
end

---@param result NgitGitResult
---@param accepted? table<integer, boolean>
---@return boolean
function M.ok(result, accepted)
  if result.code == 0 then
    return true
  end
  return accepted ~= nil and accepted[result.code] == true
end

local max_message_lines = 10
local max_message_bytes = 600

-- Git reports several ordinary refusals on stdout rather than stderr; the
-- clearest example is `git commit` answering "nothing to commit" with status 1
-- and an empty stderr. Reporting only stderr turns those into a bare exit code.
local function summarize(value)
  local trimmed = (value or ""):gsub("%s+$", "")
  if trimmed == "" then
    return ""
  end
  if #trimmed > max_message_bytes then
    trimmed = trimmed:sub(1, max_message_bytes) .. "…"
  end
  local lines = vim.split(trimmed, "\n", { plain = true })
  if #lines > max_message_lines then
    lines = vim.list_slice(lines, 1, max_message_lines)
    lines[#lines + 1] = "…"
  end
  return table.concat(lines, "\n")
end

---@param result NgitGitResult
---@return string
function M.error_message(result)
  local message = summarize(result.stderr)
  if message == "" then
    message = summarize(result.stdout)
  end
  if message == "" then
    message = ("Git exited with status %d"):format(result.code)
  end
  return message
end

---@param args string[]
---@param opts? { cwd?: string }
---@param on_chunk fun(stream: "stdout"|"stderr", data: string)
---@param callback fun(result: NgitGitResult)
---@return vim.SystemObj?
function M.run_stream(args, opts, on_chunk, callback)
  opts = opts or {}
  local command = command_for(args)
  local env = {
    LC_ALL = "C",
    GIT_PAGER = "cat",
    GIT_TERMINAL_PROMPT = "0",
  }
  local function stream(kind)
    return function(err, data)
      if err or not data or data == "" then
        return
      end
      vim.schedule(function()
        on_chunk(kind, data)
      end)
    end
  end

  local ok, process = pcall(vim.system, command, {
    cwd = opts.cwd,
    env = env,
    text = true,
    stdout = stream("stdout"),
    stderr = stream("stderr"),
  }, function(result)
    schedule(callback, {
      code = result.code,
      signal = result.signal,
      stdout = "",
      stderr = "",
      command = command,
      truncated = false,
    })
  end)
  if not ok then
    schedule(callback, {
      code = 127,
      signal = 0,
      stdout = "",
      stderr = tostring(process),
      command = command,
      truncated = false,
    })
    return nil
  end
  return process
end

return M
