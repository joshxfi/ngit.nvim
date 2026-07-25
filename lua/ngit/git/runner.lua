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

local function command_for(args)
  local command = {
    "git",
    "--no-pager",
    "--literal-pathspecs",
    "-c",
    "color.ui=false",
    "-c",
    "core.quotepath=false",
  }
  vim.list_extend(command, args)
  return command
end

function M.command(args)
  return command_for(args)
end

---@param args string[]
---@param opts? { cwd?: string, stdin?: string, readonly?: boolean, text?: boolean, max_stdout_bytes?: integer }
---@param callback fun(result: NgitGitResult)
---@return vim.SystemObj?
function M.run(args, opts, callback)
  opts = opts or {}
  local command = command_for(args)
  local env = { LC_ALL = "C", GIT_PAGER = "cat" }
  if opts.readonly ~= false then
    env.GIT_OPTIONAL_LOCKS = "0"
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

---@param result NgitGitResult
---@return string
function M.error_message(result)
  local message = result.stderr:gsub("%s+$", "")
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
