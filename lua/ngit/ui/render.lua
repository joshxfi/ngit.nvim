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

function M.status(sign, path, group)
  return build({
    { "  " },
    { sign, group },
    { " " },
    { path, "NgitPath" },
  })
end

function M.commit(oid, date, subject, decoration)
  local commit_type = subject:match("^([%w_-]+)[%(!:]")
  local type_end = commit_type and #commit_type or 0
  local row = build({
    { "  " },
    { oid, "NgitCommitHash" },
    { "  " },
    { date, "NgitDate" },
    { "  " },
    { subject },
    { decoration ~= "" and ("  " .. decoration) or "", "NgitDecoration" },
  })
  if type_end > 0 then
    local subject_start = 2 + #oid + 2 + #date + 2
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

function M.stash(ref, date, subject)
  return build({
    { "  " },
    { ref, "NgitStashRef" },
    { "  " },
    { date, "NgitDate" },
    { "  " },
    { subject },
  })
end

return M
