local M = {}

local function build(segments)
  local text = ""
  local spans = {}
  for _, segment in ipairs(segments) do
    local value = tostring(segment[1] or ""):gsub("[\r\n\t]", " ")
    local start = #text
    text = text .. value
    if segment[2] and value ~= "" then
      spans[#spans + 1] = {
        col = start,
        end_col = #text,
        group = segment[2],
      }
    end
  end
  return { text = text, spans = spans }
end

function M.section(title, count, group)
  return build({
    { " " .. title, group },
    { "  " },
    { tostring(count), "NgitMuted" },
  })
end

function M.status(sign, path, group)
  local directory, name = path:match("^(.*/)([^/]+)$")
  return build({
    { "  " },
    { sign, group },
    { " " },
    { directory or "", "NgitPathDim" },
    { name or path, "NgitPath" },
  })
end

--- Ages are right-aligned in a fixed four columns, the widest one they reach,
--- so subjects start at the same offset on every row.
local age_width = 4

local function stamp(age)
  return ("%" .. age_width .. "s"):format(age)
end

local age_units = {
  { 60, 1, "s" },
  { 3600, 60, "m" },
  { 86400, 3600, "h" },
  { 604800, 86400, "d" },
  { 2629800, 604800, "w" },
  { 31557600, 2629800, "mo" },
}

--- Compact age such as "3d" or "8mo", never wider than four columns.
---
--- An absolute date costs ten columns in a panel that is rarely wider than
--- fifty, which pushed subjects out of view. The selected entry's full date is
--- already in the preview, so the list keeps only what helps while scanning:
--- roughly how old something is.
---@param timestamp integer?
---@param now integer? seconds since the epoch, for tests
---@return string
function M.age(timestamp, now)
  if not timestamp or timestamp == 0 then
    return "?"
  end
  local delta = (now or os.time()) - timestamp
  if delta < 45 then
    return "now"
  end
  for _, unit in ipairs(age_units) do
    if delta < unit[1] then
      return ("%d%s"):format(math.floor(delta / unit[2]), unit[3])
    end
  end
  return ("%dy"):format(math.floor(delta / 31557600))
end

--- No date column: the panel is narrow, and the selected commit's full date is
--- already the third line of its preview. Stashes still carry one, because
--- `git stash show` prints no header for it to live in.
function M.commit(oid, subject, decoration)
  local commit_type = subject:match("^([%w_-]+)[%(!:]")
  local type_end = commit_type and #commit_type or 0
  local row = build({
    { "  " },
    { oid, "NgitCommitHash" },
    { "  " },
    { subject },
    { decoration ~= "" and ("  " .. decoration) or "", "NgitDecoration" },
  })
  if type_end > 0 then
    local subject_start = 2 + #oid + 2
    row.spans[#row.spans + 1] = {
      col = subject_start,
      end_col = subject_start + type_end,
      group = "NgitCommitType",
    }
  end
  return row
end

function M.branch(marker, name, subject, upstream, remote)
  return build({
    { "  " },
    { marker, remote and "NgitBranchRemote" or "NgitBranchLocal" },
    { " " },
    { name, remote and "NgitBranchRemote" or "NgitBranchLocal" },
    { "  " },
    { subject },
    { upstream, "NgitUpstream" },
  })
end

function M.stash(ref, age, subject)
  return build({
    { "  " },
    { ref, "NgitStashRef" },
    { "  " },
    { stamp(age), "NgitDate" },
    { "  " },
    { subject },
  })
end

return M
