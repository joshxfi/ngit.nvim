local runner = require("ngit.git.runner")

local M = {}

---@class NgitDiff
---@field text string
---@field lines string[]
---@field hunks integer[]
---@field files table[]
---@field metadata table
---@field truncated boolean
---@field estimated_bytes integer

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
      -- Preamble text: author, date, message, diffstat. The bare "---" is the
      -- separator git prints before a diffstat and carries nothing to show.
      if line ~= "" and line ~= "---" and not line:match("^%s*[%d]+ files? changed") then
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

local function estimated_bytes(text, lines, files)
  local total = #text
  for _, line in ipairs(lines) do
    total = total + #line
  end
  for _, file in ipairs(files) do
    total = total + #(file.old_path or "") + #(file.new_path or "") + #(file.display_path or "")
    for _, value in ipairs(file.metadata or {}) do
      total = total + #value
    end
    for _, hunk in ipairs(file.hunks or {}) do
      total = total + #(hunk.heading or "")
      for _, pair in ipairs(hunk.rows or {}) do
        total = total + #(pair.left and pair.left.text or "")
        total = total + #(pair.right and pair.right.text or "")
      end
    end
  end
  return total
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
    estimated_bytes = estimated_bytes(text, lines, files),
  }
end

--- `--ignore-space-change` rather than `--ignore-all-space`: the weaker form
--- collapses runs of whitespace but still shows a change in indentation, which in
--- an indentation-sensitive language is a change in meaning and not noise.
---
--- Either form prints the collapsed text of a line it demoted to context, so the
--- result reads correctly but cannot be handed to `git apply`. The session
--- disables hunk and line actions while the option is on for that reason; whole
--- files are unaffected, because staging one never goes through a patch.
local function args_for(section, path, context, opts)
  local args = {
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--binary",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    ("--unified=%d"):format(context),
  }
  if opts and opts.ignore_whitespace then
    args[#args + 1] = "--ignore-space-change"
  end
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
---@param opts? { ignore_whitespace?: boolean }
---@return vim.SystemObj?
function M.load(root, section, path, context, max_bytes, callback, opts)
  return runner.run(args_for(section, path, context, opts), {
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

--- Header block of the file that encloses `row`: the `diff --git` line through
--- the line before that file's first hunk.
---
--- Searching backwards from the row rather than taking the first header in the
--- stream is what makes hunk actions correct in a multi-file preview, and what
--- keeps a commit's author/date/message preamble out of the generated patch.
---@param lines string[]
---@param row integer
---@return integer first, integer last
local function file_header_range(lines, row)
  local first = 1
  for index = math.min(row, #lines), 1, -1 do
    if vim.startswith(lines[index], "diff --git ") then
      first = index
      break
    end
  end
  local last = first - 1
  for index = first, #lines do
    local line = lines[index]
    if vim.startswith(line, "@@") then
      break
    end
    if index > first and vim.startswith(line, "diff --git ") then
      break
    end
    last = index
  end
  return first, last
end

--- The hunk at or immediately before `row`, as a half-open row span.
---@param lines string[]
---@param row integer
---@return integer? first, integer? last
local function hunk_range(lines, row)
  local first
  for index = math.min(row, #lines), 1, -1 do
    local line = lines[index]
    if vim.startswith(line, "@@") then
      first = index
      break
    end
    if vim.startswith(line, "diff --git ") then
      return nil, nil
    end
  end
  if not first then
    return nil, nil
  end
  local last = #lines
  for index = first + 1, #lines do
    if vim.startswith(lines[index], "@@") or vim.startswith(lines[index], "diff --git ") then
      last = index - 1
      break
    end
  end
  return first, last
end

---@param lines string[]
---@param cursor_line integer
---@return string?
function M.patch_at_hunk(lines, cursor_line)
  local hunk_first, hunk_last = hunk_range(lines, cursor_line)
  if not hunk_first then
    return nil
  end
  local header_first, header_last = file_header_range(lines, hunk_first)
  local patch = {}
  for index = header_first, header_last do
    patch[#patch + 1] = lines[index]
  end
  for index = hunk_first, hunk_last do
    patch[#patch + 1] = lines[index]
  end
  return table.concat(patch, "\n") .. "\n"
end

--- Every `diff --git` block in a unified diff, as header and body row spans. A
--- stream carrying no header at all — `--no-index` output for an untracked file
--- — is reported as a single block whose header runs up to the first hunk.
---@param lines string[]
---@return { header_first: integer, header_last: integer, body_last: integer }[]
local function file_blocks(lines)
  local blocks = {}
  local index = 1
  while index <= #lines do
    if vim.startswith(lines[index], "diff --git ") then
      local header_last = index
      local scan = index + 1
      while
        scan <= #lines
        and not vim.startswith(lines[scan], "@@")
        and not vim.startswith(lines[scan], "diff --git ")
      do
        header_last = scan
        scan = scan + 1
      end
      local body_last = header_last
      while scan <= #lines and not vim.startswith(lines[scan], "diff --git ") do
        body_last = scan
        scan = scan + 1
      end
      blocks[#blocks + 1] =
        { header_first = index, header_last = header_last, body_last = body_last }
      index = scan
    else
      index = index + 1
    end
  end
  if #blocks == 0 then
    local header_first, header_last = file_header_range(lines, 1)
    blocks[1] = { header_first = header_first, header_last = header_last, body_last = #lines }
  end
  return blocks
end

--- Rewrites one hunk down to the selected rows, the way `git add -p` splits one.
---
--- A patch applies old→new, so rows that are *not* selected have to be rewritten
--- rather than simply dropped: whichever side already exists in the target must
--- survive as context, and whichever side does not must disappear. Applying
--- forward the target holds the old side, so an unselected `-` becomes context
--- and an unselected `+` is dropped; reversing, the target holds the new side, so
--- the two swap. Getting this backwards silently corrupts the file.
---
--- The rows also have to be re-paired. Git prints every removal of a change
--- block before every addition, so the i-th removal is the counterpart of the
--- i-th addition; emitting in stream order would place a kept addition after the
--- context lines its unselected neighbours turned into, and the staged file would
--- carry the line in the wrong place.
---@return string[]? rows, integer old_count, integer new_count, integer selected, integer total
local function narrow_hunk(lines, hunk_first, hunk_last, selected, reverse)
  local rows = {}
  local old_count, new_count, changes, total = 0, 0, 0, 0
  local deleted, added = {}, {}
  -- A "\ No newline at end of file" describes where a side stops. Left in front
  -- of a row that is still to come it would claim the file ends mid-hunk, so a
  -- marker whose owner was rewritten as context waits until nothing follows it.
  local deferred_marker, deferred_at

  local function emit(text)
    rows[#rows + 1] = text
  end

  local function defer(marker)
    deferred_marker = marker
    deferred_at = #rows
  end

  local function flush()
    for index = 1, math.max(#deleted, #added) do
      local removal = deleted[index]
      local addition = added[index]
      if removal then
        if selected[removal.row] then
          emit(removal.line)
          old_count = old_count + 1
          changes = changes + 1
          if removal.marker then
            emit(removal.marker)
          end
        elseif not reverse then
          emit(" " .. removal.text)
          old_count = old_count + 1
          new_count = new_count + 1
          if removal.marker then
            defer(removal.marker)
          end
        end
      end
      if addition then
        if selected[addition.row] then
          emit(addition.line)
          new_count = new_count + 1
          changes = changes + 1
          if addition.marker then
            emit(addition.marker)
          end
        elseif reverse then
          emit(" " .. addition.text)
          old_count = old_count + 1
          new_count = new_count + 1
          if addition.marker then
            defer(addition.marker)
          end
        end
      end
    end
    deleted, added = {}, {}
  end

  for scan = hunk_first + 1, hunk_last do
    local line = lines[scan]
    local prefix = line:sub(1, 1)
    if prefix == "-" then
      total = total + 1
      deleted[#deleted + 1] = { row = scan, line = line, text = line:sub(2) }
    elseif prefix == "+" then
      total = total + 1
      added[#added + 1] = { row = scan, line = line, text = line:sub(2) }
    elseif prefix == "\\" then
      local owner = added[#added] or deleted[#deleted]
      if owner then
        owner.marker = line
      else
        emit(line)
      end
    else
      flush()
      -- Context. Git writes a bare space for a blank line, but a stream that has
      -- been through an editor may have lost it.
      emit(line == "" and " " or line)
      old_count = old_count + 1
      new_count = new_count + 1
    end
  end
  flush()
  if deferred_marker and deferred_at == #rows then
    emit(deferred_marker)
  end

  if changes == 0 then
    return nil, 0, 0, 0, total
  end
  return rows, old_count, new_count, changes, total
end

--- Builds a patch carrying only the selected change rows, across as many files
--- of the preview as the selection touches.
---@param lines string[] unified diff the preview was built from
---@param selected table<integer, boolean> unified rows the user picked
---@param opts? { reverse?: boolean }
---@return string? patch, string? err
function M.patch_for_rows(lines, selected, opts)
  opts = opts or {}
  local reverse = opts.reverse == true
  local patch = {}

  for _, block in ipairs(file_blocks(lines)) do
    local body = {}
    local delta, block_selected, block_total = 0, 0, 0
    local index = block.header_last + 1
    while index <= block.body_last do
      if vim.startswith(lines[index], "@@") then
        local hunk_last = block.body_last
        for scan = index + 1, block.body_last do
          if vim.startswith(lines[scan], "@@") then
            hunk_last = scan - 1
            break
          end
        end
        local rows, old_count, new_count, changes, total =
          narrow_hunk(lines, index, hunk_last, selected, reverse)
        block_total = block_total + total
        local old_start, _, new_start = parse_range(lines[index])
        if rows and old_start then
          block_selected = block_selected + changes
          -- `--recount` fixes the counts but trusts the starts, and git places a
          -- hunk by the side the target holds. Applying forward that is the old
          -- side, at its recorded position because hunks left out are not
          -- applied; reversing it is the new side, which the target holds in
          -- full, so its recorded position is where the content really is. The
          -- other side shifts by whatever the hunks emitted before it changed.
          local minus_start, plus_start = old_start, old_start + delta
          if reverse then
            minus_start, plus_start = new_start - delta, new_start
          end
          body[#body + 1] = ("@@ -%d,%d +%d,%d @@"):format(
            minus_start,
            old_count,
            plus_start,
            new_count
          )
          vim.list_extend(body, rows)
          delta = delta + new_count - old_count
        end
        index = hunk_last
      end
      index = index + 1
    end

    if #body > 0 then
      -- Reversing a creation, or applying a deletion, rewrites the whole file
      -- rather than a range inside it, so git needs every row of it. Saying so
      -- beats letting git fail on a patch it cannot place.
      if block_selected < block_total then
        local header = table.concat(lines, "\n", block.header_first, block.header_last)
        local creation = header:find("new file mode", 1, true) ~= nil
        local deletion = header:find("deleted file mode", 1, true) ~= nil
        if (opts.reverse and creation) or (not opts.reverse and deletion) then
          return nil, "Whole-file additions and deletions cannot be split; act on the file instead"
        end
      end
      for row = block.header_first, block.header_last do
        patch[#patch + 1] = lines[row]
      end
      vim.list_extend(patch, body)
    end
  end

  if #patch == 0 then
    return nil, nil
  end
  return table.concat(patch, "\n") .. "\n", nil
end

return M
