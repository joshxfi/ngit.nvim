local M = {}
M.__index = M

---@param capacity integer
function M.new(capacity)
  return setmetatable({ capacity = capacity, values = {}, order = {} }, M)
end

function M:get(key)
  local value = self.values[key]
  if value == nil then
    return nil
  end
  for index, candidate in ipairs(self.order) do
    if candidate == key then
      table.remove(self.order, index)
      break
    end
  end
  self.order[#self.order + 1] = key
  return value
end

function M:set(key, value)
  if self.values[key] ~= nil then
    for index, candidate in ipairs(self.order) do
      if candidate == key then
        table.remove(self.order, index)
        break
      end
    end
  end
  self.values[key] = value
  self.order[#self.order + 1] = key
  while #self.order > self.capacity do
    local oldest = table.remove(self.order, 1)
    self.values[oldest] = nil
  end
end

function M:clear()
  self.values = {}
  self.order = {}
end

return M
