local runner = require("ngit.git.runner")

local M = {}

---@class NgitDiff
---@field text string
---@field lines string[]
---@field hunks integer[]
---@field files table[]
---@field metadata table
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

local function unquote_path(value)
  value = value:gsub("\t.*$", "")
  if value == "/dev/null" then
    return nil
  end
  if value:sub(1, 1) ~= '"' then
    return value:gsub("^[ab]/", "")
  end
  value = value:sub(2, -2)
  value = value:gsub("\\([0-7][0-7][0-7])", function(octal)
    return string.char(tonumber(octal, 8))
  end)
  local escapes = { n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\" }
  value = value:gsub("\\(.)", function(char)
    return escapes[char] or char
  end)
  return value:gsub("^[ab]/", "")
end

local function diff_header_paths(line)
  local value = line:sub(#"diff --git " + 1)
  local old_path, new_path = value:match('^(.-) ("b/.*")$')
  if not old_path then
    old_path, new_path = value:match('^("a/.-") (b/.+)$')
  end
  if not old_path then
    old_path, new_path = value:match("^a/(.-) b/(.+)$")
    if old_path then
      old_path = "a/" .. old_path
      new_path = "b/" .. new_path
    end
  end
  if not old_path then
    return nil, nil
  end
  return unquote_path(old_path), unquote_path(new_path)
end

local function parse_range(header)
  local old_start, old_count, new_start, new_count, heading =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@(.*)$")
  if not old_start then
    return nil
  end
  return tonumber(old_start),
    tonumber(old_count ~= "" and old_count or "1"),
    tonumber(new_start),
    tonumber(new_count ~= "" and new_count or "1"),
    vim.trim(heading or "")
end

local function parse_hunk(lines, start_row, stop_row)
  local old_start, old_count, new_start, new_count, heading = parse_range(lines[start_row])
  if not old_start then
    return nil
  end
  local hunk = {
    unified_start = start_row,
    unified_end = stop_row,
    old_start = old_start,
    old_count = old_count,
    new_start = new_start,
    new_count = new_count,
    heading = heading,
    rows = {},
  }
  local old_number = old_start
  local new_number = new_start
  local deleted = {}
  local added = {}
  local last_side

  local function flush_changes()
    local count = math.max(#deleted, #added)
    for index = 1, count do
      local left = deleted[index]
      local right = added[index]
      if left then
        left.kind = right and "change" or "delete"
      end
      if right then
        right.kind = left and "change" or "add"
      end
      hunk.rows[#hunk.rows + 1] = {
        left = left,
        right = right,
        unified_start = start_row,
      }
    end
    deleted = {}
    added = {}
  end

  for row = start_row + 1, stop_row do
    local line = lines[row]
    local prefix = line:sub(1, 1)
    if prefix == " " then
      flush_changes()
      local text = line:sub(2)
      hunk.rows[#hunk.rows + 1] = {
        left = { text = text, number = old_number, kind = "context", unified_row = row },
        right = { text = text, number = new_number, kind = "context", unified_row = row },
        unified_start = start_row,
      }
      old_number = old_number + 1
      new_number = new_number + 1
      last_side = "both"
    elseif prefix == "-" then
      deleted[#deleted + 1] = {
        text = line:sub(2),
        number = old_number,
        kind = "delete",
        unified_row = row,
      }
      old_number = old_number + 1
      last_side = "left"
    elseif prefix == "+" then
      added[#added + 1] = {
        text = line:sub(2),
        number = new_number,
        kind = "add",
        unified_row = row,
      }
      new_number = new_number + 1
      last_side = "right"
    elseif prefix == "\\" then
      local collection = last_side == "left" and deleted or (last_side == "right" and added or nil)
      if collection and collection[#collection] then
        collection[#collection].no_newline = true
      end
    end
  end
  flush_changes()
  return hunk
end

local function structured_diff(lines)
  local files = {}
  local metadata = { lines = {}, additions = 0, deletions = 0 }
  local current
  local index = 1
  while index <= #lines do
    local line = lines[index]
    if vim.startswith(line, "diff --git ") then
      current = {
        old_path = nil,
        new_path = nil,
        display_path = "(unknown)",
        metadata = {},
        binary = false,
        hunks = {},
        additions = 0,
        deletions = 0,
      }
      local old_path, new_path = diff_header_paths(line)
      if old_path and new_path then
        current.old_path = old_path
        current.new_path = new_path
        current.display_path = current.new_path
      end
      files[#files + 1] = current
    elseif not current then
      if line ~= "" and not line:match("^%s*[%d]+ files? changed") then
        metadata.lines[#metadata.lines + 1] = line
      end
    elseif vim.startswith(line, "--- ") then
      current.old_path = unquote_path(line:sub(5))
    elseif vim.startswith(line, "+++ ") then
      current.new_path = unquote_path(line:sub(5))
      current.display_path = current.new_path or current.old_path or "(unknown)"
    elseif vim.startswith(line, "Binary files ") or line == "GIT binary patch" then
      current.binary = true
      local old_path, new_path = line:match("^Binary files (.+) and (.+) differ$")
      if old_path and new_path then
        current.old_path = unquote_path(old_path)
        current.new_path = unquote_path(new_path)
        current.display_path = current.new_path or current.old_path or "(unknown)"
      end
    elseif vim.startswith(line, "@@") then
      local stop = index + 1
      while
        stop <= #lines
        and not vim.startswith(lines[stop], "@@")
        and not vim.startswith(lines[stop], "diff --git ")
      do
        stop = stop + 1
      end
      local hunk = parse_hunk(lines, index, stop - 1)
      if hunk then
        current.hunks[#current.hunks + 1] = hunk
        for _, pair in ipairs(hunk.rows) do
          if pair.left and pair.left.kind == "delete" then
            current.deletions = current.deletions + 1
          elseif pair.left and pair.left.kind == "change" then
            current.deletions = current.deletions + 1
          end
          if pair.right and pair.right.kind == "add" then
            current.additions = current.additions + 1
          elseif pair.right and pair.right.kind == "change" then
            current.additions = current.additions + 1
          end
        end
      end
      index = stop - 1
    elseif line ~= "" and not vim.startswith(line, "index ") then
      if vim.startswith(line, "rename from ") or vim.startswith(line, "copy from ") then
        current.old_path = unquote_path(line:match("^%S+ from (.*)$") or "")
        current.metadata[#current.metadata + 1] = line
      elseif vim.startswith(line, "rename to ") or vim.startswith(line, "copy to ") then
        current.new_path = unquote_path(line:match("^%S+ to (.*)$") or "")
        current.display_path = current.new_path or current.old_path or "(unknown)"
        current.metadata[#current.metadata + 1] = line
      elseif
        vim.startswith(line, "new file mode ")
        or vim.startswith(line, "deleted file mode ")
        or vim.startswith(line, "old mode ")
        or vim.startswith(line, "new mode ")
      then
        current.metadata[#current.metadata + 1] = line
      end
    end
    index = index + 1
  end
  for _, file in ipairs(files) do
    file.display_path = file.new_path or file.old_path or file.display_path
    metadata.additions = metadata.additions + file.additions
    metadata.deletions = metadata.deletions + file.deletions
  end
  metadata.file_count = #files
  return files, metadata
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
    text = text .. "\n[ngit: preview truncated; increase max_diff_bytes to load more]\n"
  end
  local lines, hunks = lines_and_hunks(text)
  local files, metadata = structured_diff(lines)
  return {
    text = text,
    lines = lines,
    hunks = hunks,
    files = files,
    metadata = metadata,
    truncated = truncated,
  }
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
