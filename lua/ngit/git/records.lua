local M = {}

---@param text string
---@param separator string
---@return string[]
function M.split(text, separator)
  local values = {}
  local start = 1
  while start <= #text do
    local stop = text:find(separator, start, true)
    if not stop then
      values[#values + 1] = text:sub(start)
      break
    end
    values[#values + 1] = text:sub(start, stop - 1)
    start = stop + #separator
  end
  return values
end

---@param output string
---@return string[][]
function M.control_records(output)
  local parsed = {}
  for _, record in ipairs(M.split(output, string.char(30))) do
    record = record:gsub("^\n", ""):gsub("\n$", "")
    if record ~= "" then
      local fields = M.split(record, "\0")
      if fields[#fields] == "" then
        table.remove(fields)
      end
      parsed[#parsed + 1] = fields
    end
  end
  return parsed
end

return M
