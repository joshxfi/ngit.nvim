local mutate = require("ngit.git.mutate")
local runner = require("ngit.git.runner")

local M = {}

-- Git writes seven marker characters unless a `conflict-marker-size`
-- attribute asks for more, so seven is only the shortest run that can count.
local min_marker_size = 7

---@class NgitConflictBlock
---@field start integer Line carrying the `<<<<<<<` marker.
---@field middle integer Line carrying the `=======` marker.
---@field finish integer Line carrying the `>>>>>>>` marker.
---@field base? integer Line carrying the `|||||||` marker, in diff3 style.
---@field ours_label string
---@field theirs_label string
---@field size integer Length of the marker runs that delimit this block.

--- Length and label of a marker line, or nil when the line is not one.
---
--- A marker is a run of one character, at least seven long, followed by a space
--- and a label or by the end of the line. Which runs delimit a block is settled
--- by its opening line: git writes all four markers of a block at one length,
--- so a longer run inside it is text that happens to look the same, such as a
--- Markdown or reStructuredText underline, or the longer markers git nests
--- inside a recursive merge base.
---@param line string
---@param char string
---@return integer? size, string? label
local function marker(line, char)
  local run = line:match("^" .. vim.pesc(char) .. "+")
  if not run or #run < min_marker_size then
    return nil
  end
  local rest = line:sub(#run + 1):gsub("\r$", "")
  if rest == "" then
    return #run, ""
  end
  if rest:match("^%s") then
    return #run, vim.trim(rest)
  end
  return nil
end

--- Conflict blocks in a worktree file, in order.
---
--- A block only counts once it is complete: a file can legitimately contain a
--- line of angle brackets, and half a marker set is not something to rewrite.
--- A block that carries a second separator or base marker, or that has a
--- separator but never closes, cannot be split without guessing which lines git
--- wrote, so it is returned separately as ambiguous and never rewritten.
---@param lines string[]
---@return NgitConflictBlock[] blocks, { start: integer, finish: integer }[] ambiguous
function M.parse_markers(lines)
  local blocks, ambiguous = {}, {}
  local current
  -- Inside a block only runs of the block's own length are markers.
  local function at_size(line, char)
    local size, label = marker(line, char)
    if size and size == current.size then
      return label
    end
    return nil
  end
  for index, line in ipairs(lines) do
    local opening, ours = marker(line, "<")
    if opening and (not current or opening == current.size) then
      if current and current.middle then
        ambiguous[#ambiguous + 1] = { start = current.start, finish = index - 1 }
      end
      current = { start = index, ours_label = ours, size = opening }
    elseif current and at_size(line, "|") then
      if current.base or current.middle then
        current.ambiguous = true
      else
        current.base = index
      end
    elseif current and at_size(line, "=") then
      if current.middle then
        current.ambiguous = true
      else
        current.middle = index
      end
    elseif current then
      local theirs = at_size(line, ">")
      if theirs then
        if current.middle and not current.ambiguous then
          current.finish = index
          current.theirs_label = theirs
          current.ambiguous = nil
          blocks[#blocks + 1] = current
        else
          ambiguous[#ambiguous + 1] = { start = current.start, finish = index }
        end
        current = nil
      end
    end
  end
  if current and current.middle then
    ambiguous[#ambiguous + 1] = { start = current.start, finish = #lines }
  end
  return blocks, ambiguous
end

--- Whether any conflict block is left, complete or ambiguous. Staging is refused
--- while one is, so a block ngit could not parse is never marked resolved by
--- accident, while a stray marker-shaped line outside a block does not hold the
--- file hostage.
---@param lines string[]
---@return boolean
function M.has_markers(lines)
  local blocks, ambiguous = M.parse_markers(lines)
  return #blocks > 0 or #ambiguous > 0
end

--- Body of one side of a block, with the markers and the unwanted side removed.
--- In diff3 style the common ancestor sits between `|||||||` and `=======`, so
--- "ours" stops at whichever of the two comes first.
local function kept_lines(lines, block, side)
  local kept = {}
  if side == "ours" or side == "both" then
    for index = block.start + 1, (block.base or block.middle) - 1 do
      kept[#kept + 1] = lines[index]
    end
  end
  if side == "theirs" or side == "both" then
    for index = block.middle + 1, block.finish - 1 do
      kept[#kept + 1] = lines[index]
    end
  end
  return kept
end

--- Rewrites the named blocks, leaving everything else byte for byte.
---@param lines string[]
---@param blocks NgitConflictBlock[] ascending, and a subset of the parsed blocks
---@param side "ours"|"theirs"|"both"
---@return string[]
function M.resolve_lines(lines, blocks, side)
  local out = {}
  local next_block = 1
  local index = 1
  while index <= #lines do
    local block = blocks[next_block]
    if block and index == block.start then
      vim.list_extend(out, kept_lines(lines, block, side))
      index = block.finish + 1
      next_block = next_block + 1
    else
      out[#out + 1] = lines[index]
      index = index + 1
    end
  end
  return out
end

--- Reads a worktree file preserving whether it ended with a newline, so
--- rewriting one conflict block cannot silently add or remove one.
---
--- This is deliberately synchronous. It runs only when the reader presses a
--- resolve or navigate key, on a file small enough to be conflicted and already
--- warm in the page cache; making it asynchronous would add a callback layer to
--- every conflict action for no measurable gain.
---@param absolute string
---@return string[]? lines, boolean trailing_newline
local function read_lines(absolute)
  local file = io.open(absolute, "rb")
  if not file then
    return nil, false
  end
  local content = file:read("*a") or ""
  file:close()
  local trailing = content:sub(-1) == "\n"
  if trailing then
    content = content:sub(1, -2)
  end
  return vim.split(content, "\n", { plain = true }), trailing
end

local function write_lines(absolute, lines, trailing)
  local file = io.open(absolute, "wb")
  if not file then
    return false
  end
  file:write(table.concat(lines, "\n"))
  if trailing then
    file:write("\n")
  end
  file:close()
  return true
end

--- Parsed blocks of a worktree file, plus the ambiguous ones that are left for
--- the reader to resolve by hand.
---@param root string
---@param path string
---@return NgitConflictBlock[]?, string?, { start: integer, finish: integer }[]?
function M.blocks(root, path)
  local lines = read_lines(vim.fs.joinpath(root, path))
  if not lines then
    return nil, ("Unable to read %s"):format(path)
  end
  local blocks, ambiguous = M.parse_markers(lines)
  return blocks, nil, ambiguous
end

local ambiguous_message = "This conflict block has more than one separator; resolve it by hand"

--- Resolves one block, or every block when `line` is nil, and stages the file
--- once no markers are left.
---
--- Taking a side for the whole file goes through `git checkout --ours/--theirs`
--- rather than this rewrite, because that restores the recorded stage exactly,
--- including a file one side deleted. Taking both sides has no git equivalent, so
--- it is always the rewrite.
---@param root string
---@param path string
---@param side "ours"|"theirs"|"both"
---@param line integer? worktree line inside the block to resolve
---@param callback fun(ok: boolean, err: string?, warning: string?)
function M.resolve(root, path, side, line, callback)
  local absolute = vim.fs.joinpath(root, path)
  local lines, trailing = read_lines(absolute)
  if not lines then
    callback(false, ("Unable to read %s"):format(path))
    return
  end
  local blocks, ambiguous = M.parse_markers(lines)
  for _, range in ipairs(ambiguous) do
    if #blocks == 0 or (line and line >= range.start and line <= range.finish) then
      callback(false, ambiguous_message)
      return
    end
  end
  if #blocks == 0 then
    callback(false, ("%s carries no conflict markers"):format(path))
    return
  end

  local selected = blocks
  if line then
    selected = nil
    for _, block in ipairs(blocks) do
      if line >= block.start and line <= block.finish then
        selected = { block }
        break
      end
    end
    if not selected then
      callback(false, "The cursor is not inside a conflict block")
      return
    end
  end

  local resolved = M.resolve_lines(lines, selected, side)
  if not write_lines(absolute, resolved, trailing) then
    callback(false, ("Unable to write %s"):format(path))
    return
  end

  -- Still conflicted, so staging now would mark it resolved while markers are
  -- left in the file. That includes a block too ambiguous to rewrite, which a
  -- whole-file pass skips; the reader is told rather than left to find it.
  local remaining, left_ambiguous = M.parse_markers(resolved)
  if #left_ambiguous > 0 and not line then
    local count = #left_ambiguous
    callback(
      true,
      nil,
      ("%d ambiguous conflict block%s left in %s; resolve %s by hand"):format(
        count,
        count == 1 and " was" or "s were",
        path,
        count == 1 and "it" or "them"
      )
    )
    return
  end
  if #remaining > 0 or #left_ambiguous > 0 then
    callback(true, nil)
    return
  end
  mutate.stage_file(root, path, callback)
end

---@param root string
---@param path string
---@param side "ours"|"theirs"|"both"
---@param callback fun(ok: boolean, err: string?)
function M.choose(root, path, side, callback)
  if side == "both" then
    return M.resolve(root, path, "both", nil, callback)
  end
  runner.run(
    { "checkout", "--" .. side, "--", path },
    { cwd = root, readonly = false },
    function(result)
      if not runner.ok(result) then
        callback(false, runner.error_message(result))
        return
      end
      mutate.stage_file(root, path, callback)
    end
  )
end

--- The three recorded stages of a conflicted path: base, ours, theirs.
---@param root string
---@param path string
---@param callback fun(stages: { base?: string, ours?: string, theirs?: string }?, err: string?)
function M.stages(root, path, callback)
  return runner.run({ "ls-files", "--stage", "--", path }, { cwd = root }, function(result)
    if not runner.ok(result) then
      callback(nil, runner.error_message(result))
      return
    end
    local names = { [1] = "base", [2] = "ours", [3] = "theirs" }
    local stages = {}
    for _, line in ipairs(vim.split(result.stdout, "\n", { plain = true, trimempty = true })) do
      local oid, stage = line:match("^%d+ (%x+) (%d)\t")
      if oid and names[tonumber(stage)] then
        stages[names[tonumber(stage)]] = oid
      end
    end
    callback(stages, nil)
  end)
end

return M
