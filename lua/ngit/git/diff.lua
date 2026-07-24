local runner = require("ngit.git.runner")

local M = {}

---@class NgitDiff
---@field text string
---@field lines string[]
---@field hunks integer[]
---@field truncated boolean

local function lines_and_hunks(text)
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  local hunks = {}
  for index, line in ipairs(lines) do
    if vim.startswith(line, "@@") then
      hunks[#hunks + 1] = index
    end
  end
  return lines, hunks
end

---@param text string
---@param max_bytes integer
---@param forced_truncation? boolean
---@return NgitDiff
function M.parse(text, max_bytes, forced_truncation)
  local truncated = forced_truncation == true or #text > max_bytes
  if truncated then
    text = text:sub(1, max_bytes)
    local last_newline = text:match(".*()\n")
    if last_newline then
      text = text:sub(1, last_newline)
    end
    text = text
      .. "\n[ngit: preview truncated; increase max_diff_bytes to load more]\n"
  end
  local lines, hunks = lines_and_hunks(text)
  return { text = text, lines = lines, hunks = hunks, truncated = truncated }
end

local function args_for(section, path, context)
  local args = {
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    ("--unified=%d"):format(context),
  }
  if section == "staged" then
    args[#args + 1] = "--cached"
  elseif section == "untracked" then
    return {
      "diff",
      "--no-index",
      "--no-color",
      "--no-ext-diff",
      "--binary",
      ("--unified=%d"):format(context),
      "--",
      "/dev/null",
      path,
    }
  end
  args[#args + 1] = "--"
  args[#args + 1] = path
  return args
end

---@param root string
---@param section string
---@param path string
---@param context integer
---@param max_bytes integer
---@param callback fun(diff: NgitDiff?, err: string?)
---@return vim.SystemObj?
function M.load(root, section, path, context, max_bytes, callback)
  return runner.run(args_for(section, path, context), {
    cwd = root,
    max_stdout_bytes = max_bytes,
  }, function(result)
    local accepted = section == "untracked" and { [1] = true } or nil
    if not result.truncated and not runner.ok(result, accepted) then
      callback(nil, runner.error_message(result))
      return
    end
    callback(M.parse(result.stdout, max_bytes, result.truncated), nil)
  end)
end

---@param lines string[]
---@param cursor_line integer
---@return string?
function M.patch_at_hunk(lines, cursor_line)
  local header_end
  local selected_hunk
  for index, line in ipairs(lines) do
    if vim.startswith(line, "@@") then
      header_end = header_end or (index - 1)
      if index <= cursor_line then
        selected_hunk = index
      elseif selected_hunk then
        break
      end
    end
  end
  if not selected_hunk or not header_end then
    return nil
  end

  local next_hunk = #lines + 1
  for index = selected_hunk + 1, #lines do
    if vim.startswith(lines[index], "@@") or vim.startswith(lines[index], "diff --git ") then
      next_hunk = index
      break
    end
  end

  local patch = {}
  for index = 1, header_end do
    patch[#patch + 1] = lines[index]
  end
  for index = selected_hunk, next_hunk - 1 do
    patch[#patch + 1] = lines[index]
  end
  return table.concat(patch, "\n") .. "\n"
end

return M
