local mutate = require("ngit.git.mutate")
local runner = require("ngit.git.runner")

local M = {}

local ours_marker = "<<<<<<<"
local base_marker = "|||||||"
local split_marker = "======="
local theirs_marker = ">>>>>>>"

---@class NgitConflictBlock
---@field start integer Line carrying the `<<<<<<<` marker.
---@field middle integer Line carrying the `=======` marker.
---@field finish integer Line carrying the `>>>>>>>` marker.
---@field base? integer Line carrying the `|||||||` marker, in diff3 style.
---@field ours_label string
---@field theirs_label string

--- Label after a marker, or nil when the line is not that marker.
---
--- Git writes every marker as exactly seven characters followed by a space and
--- a label, or by the end of the line. Anything longer is text that happens to
--- start the same way: a Markdown or reStructuredText underline, or the longer
--- markers git itself nests inside a recursive merge base.
---@param line string
---@param marker string
---@return string?
local function marker_label(line, marker)
  if line:sub(1, #marker) ~= marker then
    return nil
  end
  local rest = line:sub(#marker + 1):gsub("\r$", "")
  if rest == "" then
    return ""
  end
  if rest:match("^%s") then
    return vim.trim(rest)
  end
  return nil
end

--- Conflict blocks in a worktree file, in order.
---
--- A block only counts once it is complete: a file can legitimately contain a
--- line of angle brackets, and half a marker set is not something to rewrite.
--- A block that carries a second separator or base marker cannot be split
--- without guessing which one git wrote, so it is returned separately as
--- ambiguous and never rewritten.
---@param lines string[]
---@return NgitConflictBlock[] blocks, { start: integer, finish: integer }[] ambiguous
function M.parse_markers(lines)
  local blocks, ambiguous = {}, {}
  local current
  for index, line in ipairs(lines) do
    local ours = marker_label(line, ours_marker)
    if ours then
      if current then
        ambiguous[#ambiguous + 1] = { start = current.start, finish = index - 1 }
      end
      current = { start = index, ours_label = ours }
    elseif current and marker_label(line, base_marker) then
      if current.base or current.middle then
        current.ambiguous = true
      else
        current.base = index
      end
    elseif current and marker_label(line, split_marker) then
      if current.middle then
        current.ambiguous = true
      else
        current.middle = index
      end
    elseif current and marker_label(line, theirs_marker) then
      if current.middle and not current.ambiguous then
        current.finish = index
        current.theirs_label = marker_label(line, theirs_marker)
        current.ambiguous = nil
        blocks[#blocks + 1] = current
      else
        ambiguous[#ambiguous + 1] = { start = current.start, finish = index }
      end
      current = nil
    end
  end
  return blocks, ambiguous
end

--- Whether any line still opens or closes a conflict, complete or not. Staging
--- is refused while one does, so a block ngit could not parse is never marked
--- resolved by accident.
---@param lines string[]
---@return boolean
function M.has_markers(lines)
  for _, line in ipairs(lines) do
    if marker_label(line, ours_marker) or marker_label(line, theirs_marker) then
      return true
    end
  end
  return false
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

---@param root string
---@param path string
---@return NgitConflictBlock[]?, string?
function M.blocks(root, path)
  local lines = read_lines(vim.fs.joinpath(root, path))
  if not lines then
    return nil, ("Unable to read %s"):format(path)
  end
  return M.parse_markers(lines), nil
end

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
---@param callback fun(ok: boolean, err: string?)
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
      callback(false, "This conflict block has more than one separator; resolve it by hand")
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

  if not write_lines(absolute, M.resolve_lines(lines, selected, side), trailing) then
    callback(false, ("Unable to write %s"):format(path))
    return
  end

  if M.has_markers(select(1, read_lines(absolute)) or {}) then
    -- Still conflicted, so staging now would mark it resolved while markers are
    -- left in the file. That includes a block too ambiguous to rewrite.
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
