local M = {}

local function sanitize(value)
  local cleaned = (value or ""):gsub("\r", ""):gsub("\t", "  "):gsub("[%z\1-\8\11\12\14-\31]", "")
  return cleaned
end

local function line_group(kind)
  if kind == "add" then
    return "NgitDiffAdd"
  elseif kind == "delete" then
    return "NgitDiffDelete"
  elseif kind == "change" then
    return "NgitDiffChange"
  elseif kind == "filler" then
    return "NgitDiffFiller"
  elseif kind == "meta" then
    return "NgitDiffMeta"
  elseif kind == "header" or kind == "hunk" then
    return "NgitDiffHeader"
  end
end

local function changed_span(left, right)
  if #left > 4096 or #right > 4096 or left == right then
    return nil, nil
  end
  local prefix = 0
  local shortest = math.min(#left, #right)
  while prefix < shortest and left:byte(prefix + 1) == right:byte(prefix + 1) do
    prefix = prefix + 1
  end
  while prefix > 0 do
    local left_next = left:byte(prefix + 1)
    local right_next = right:byte(prefix + 1)
    local left_boundary = not left_next or left_next < 128 or left_next >= 192
    local right_boundary = not right_next or right_next < 128 or right_next >= 192
    if left_boundary and right_boundary then
      break
    end
    prefix = prefix - 1
  end

  local suffix = 0
  while
    suffix < math.min(#left - prefix, #right - prefix)
    and left:byte(#left - suffix) == right:byte(#right - suffix)
  do
    suffix = suffix + 1
  end
  while suffix > 0 do
    local left_start = left:byte(#left - suffix + 1)
    local right_start = right:byte(#right - suffix + 1)
    local left_boundary = not left_start or left_start < 128 or left_start >= 192
    local right_boundary = not right_start or right_start < 128 or right_start >= 192
    if left_boundary and right_boundary then
      break
    end
    suffix = suffix - 1
  end

  local function span(value)
    local finish = #value - suffix
    if finish <= prefix then
      return nil
    end
    return { col = prefix, end_col = finish }
  end
  return span(left), span(right)
end

local function pane()
  return {
    lines = {},
    source_numbers = {},
    source_kinds = {},
    row_hunks = {},
    -- Row in the raw unified diff that produced this display row. Line-level
    -- staging needs it to name exactly which rows of the patch the user picked,
    -- and a plain array store per row is the cheapest way to carry it: deriving
    -- it later would mean rescanning the hunk on every keypress.
    unified_rows = {},
    file_rows = {},
    highlights = {},
  }
end

local function append(target, text, number, kind, hunk, unified_row)
  target.lines[#target.lines + 1] = sanitize(text)
  target.source_numbers[#target.lines] = number or false
  target.source_kinds[#target.lines] = kind or false
  target.unified_rows[#target.lines] = unified_row or false
  if hunk then
    target.row_hunks[#target.lines] = hunk
  end
  local group = line_group(kind)
  if group then
    target.highlights[#target.highlights + 1] = {
      row = #target.lines - 1,
      group = group,
      line = true,
      priority = (kind == "header" or kind == "hunk") and 80 or 50,
    }
  end
end

--- The header window stays a fixed two lines. Author, date, commit message and
--- diffstat used to be squeezed in here and silently cut off after four lines;
--- they now lead the scrollable body instead, where their length does not
--- shift the layout.
local function header(diff, opts)
  local metadata = diff.metadata or {}
  local count = metadata.file_count or #(diff.files or {})
  return {
    sanitize(opts.title or "Diff"),
    ("%d file%s · +%d -%d%s"):format(
      count,
      count == 1 and "" or "s",
      metadata.additions or 0,
      metadata.deletions or 0,
      diff.truncated and " · truncated" or ""
    ),
  }
end

function M.split(diff, opts)
  opts = opts or {}
  local model = {
    header = header(diff, opts),
    left = pane(),
    right = pane(),
    files = {},
    -- Parallel to `files`: which file each header row introduces, so a row can
    -- be traced back to a path without a second pass over the diff.
    file_spans = {},
    hunks = {},
  }

  -- Everything git printed before the first patch header: author, date, the
  -- full commit message, and the diffstat. Both panes carry it so the block
  -- reads as one banner across a side-by-side view.
  local preamble = (diff.metadata or {}).lines or {}
  for _, line in ipairs(preamble) do
    append(model.left, line, nil, "meta")
    append(model.right, line, nil, "meta")
  end
  if #preamble > 0 then
    append(model.left, "", nil, "meta")
    append(model.right, "", nil, "meta")
  end

  for _, file in ipairs(diff.files or {}) do
    local file_row = #model.left.lines + 1
    model.files[#model.files + 1] = file_row
    model.file_spans[#model.file_spans + 1] = { row = file_row, file = file }
    model.left.file_rows[#model.left.file_rows + 1] = file_row
    model.right.file_rows[#model.right.file_rows + 1] = file_row
    local label = ("── %s  +%d -%d ──"):format(
      sanitize(file.display_path),
      file.additions or 0,
      file.deletions or 0
    )
    append(model.left, label, nil, "header")
    append(model.right, label, nil, "header")

    if file.binary or #file.hunks == 0 then
      local detail = file.binary and "Binary file changed"
        or (#file.metadata > 0 and table.concat(file.metadata, " · ") or "Metadata-only change")
      append(model.left, detail, nil, "filler")
      append(model.right, detail, nil, "filler")
    end

    for _, hunk in ipairs(file.hunks) do
      local hunk_row = #model.left.lines + 1
      model.hunks[#model.hunks + 1] = hunk_row
      local label_hunk = ("··· -%d,%d  +%d,%d%s ···"):format(
        hunk.old_start,
        hunk.old_count,
        hunk.new_start,
        hunk.new_count,
        hunk.heading ~= "" and ("  " .. hunk.heading) or ""
      )
      append(model.left, label_hunk, nil, "hunk", hunk.unified_start, hunk.unified_start)
      append(model.right, label_hunk, nil, "hunk", hunk.unified_start, hunk.unified_start)
      for _, pair in ipairs(hunk.rows) do
        local left = pair.left
        local right = pair.right
        append(
          model.left,
          left and left.text or "",
          left and left.number or nil,
          left and (left.kind == "change" and "delete" or left.kind) or "filler",
          hunk.unified_start,
          left and left.unified_row or nil
        )
        append(
          model.right,
          right and right.text or "",
          right and right.number or nil,
          right and (right.kind == "change" and "add" or right.kind) or "filler",
          hunk.unified_start,
          right and right.unified_row or nil
        )
        if left and right and left.kind == "change" and right.kind == "change" then
          local left_span, right_span = changed_span(left.text, right.text)
          if left_span then
            left_span.row = #model.left.lines - 1
            left_span.group = "NgitDiffDeleteText"
            left_span.priority = 200
            model.left.highlights[#model.left.highlights + 1] = left_span
          end
          if right_span then
            right_span.row = #model.right.lines - 1
            right_span.group = "NgitDiffAddText"
            right_span.priority = 200
            model.right.highlights[#model.right.highlights + 1] = right_span
          end
        end
      end
    end
  end

  if #model.left.lines == 0 then
    append(model.left, "No textual diff.", nil, "filler")
    append(model.right, "No textual diff.", nil, "filler")
  end
  return model
end

function M.unified(diff, opts, split)
  split = split or M.split(diff, opts)
  local unified = pane()
  local unified_hunks = {}
  local last_hunk
  local file_rows = {}
  local left_line_groups = {}
  local right_line_groups = {}
  local left_inline = {}
  local right_inline = {}
  for _, row in ipairs(split.left.file_rows) do
    file_rows[row] = true
  end
  for _, item in ipairs(split.left.highlights) do
    if item.line then
      left_line_groups[item.row + 1] = item.group
    else
      left_inline[item.row + 1] = left_inline[item.row + 1] or {}
      left_inline[item.row + 1][#left_inline[item.row + 1] + 1] = item
    end
  end
  for _, item in ipairs(split.right.highlights) do
    if item.line then
      right_line_groups[item.row + 1] = item.group
    else
      right_inline[item.row + 1] = right_inline[item.row + 1] or {}
      right_inline[item.row + 1][#right_inline[item.row + 1] + 1] = item
    end
  end
  local function append_inline(items, offset)
    for _, item in ipairs(items or {}) do
      unified.highlights[#unified.highlights + 1] = {
        row = #unified.lines - 1,
        col = item.col + offset,
        end_col = item.end_col + offset,
        group = item.group,
        priority = item.priority,
      }
    end
  end
  for row = 1, #split.left.lines do
    local left = split.left.lines[row]
    local right = split.right.lines[row]
    local left_number = split.left.source_numbers[row]
    local right_number = split.right.source_numbers[row]
    local hunk = split.left.row_hunks[row] or split.right.row_hunks[row]
    if hunk and hunk ~= last_hunk then
      unified_hunks[#unified_hunks + 1] = #unified.lines + 1
      last_hunk = hunk
    end
    local left_group = left_line_groups[row]
    local right_group = right_line_groups[row]
    local left_source = split.left.unified_rows[row]
    local right_source = split.right.unified_rows[row]
    if left_group == "NgitDiffMeta" then
      append(unified, left, nil, "meta", hunk)
    elseif left_group == "NgitDiffHeader" then
      append(unified, left, nil, "header", hunk, left_source or nil)
      if file_rows[row] then
        unified.file_rows[#unified.file_rows + 1] = #unified.lines
      end
    elseif left_group == "NgitDiffDelete" or left_group == "NgitDiffChange" then
      append(unified, "- " .. left, left_number, "delete", hunk, left_source or nil)
      append_inline(left_inline[row], 2)
      if right_group == "NgitDiffAdd" or right_group == "NgitDiffChange" then
        append(unified, "+ " .. right, right_number, "add", hunk, right_source or nil)
        append_inline(right_inline[row], 2)
      end
    elseif right_group == "NgitDiffAdd" then
      append(unified, "+ " .. right, right_number, "add", hunk, right_source or nil)
      append_inline(right_inline[row], 2)
    elseif left_group == "NgitDiffFiller" and right_group == "NgitDiffFiller" then
      append(unified, left ~= "" and left or right, nil, "filler", hunk)
    else
      append(
        unified,
        "  " .. left,
        left_number or right_number,
        nil,
        hunk,
        left_source or right_source or nil
      )
    end
  end

  -- Files appear in the same order in both layouts and each contributes exactly
  -- one header row, so the split model's file list transfers by index.
  local file_spans = {}
  for index, row in ipairs(unified.file_rows) do
    local span = split.file_spans[index]
    if span then
      file_spans[#file_spans + 1] = { row = row, file = span.file }
    end
  end

  return {
    header = split.header,
    unified = unified,
    files = unified.file_rows,
    file_spans = file_spans,
    hunks = unified_hunks,
  }
end

function M.filetype(diff)
  if #(diff.files or {}) ~= 1 or diff.files[1].binary then
    return nil
  end
  local path = diff.files[1].new_path or diff.files[1].old_path
  if not path then
    return nil
  end
  return vim.filetype.match({ filename = path })
end

return M
