local M = {}
M.__index = M

---@param capacity integer
---@param opts? { max_weight?: integer, weigh?: fun(value: any): integer }
function M.new(capacity, opts)
  opts = opts or {}
  return setmetatable({
    capacity = capacity,
    max_weight = opts.max_weight,
    weigh = opts.weigh or function()
      return 1
    end,
    values = {},
    weights = {},
    total_weight = 0,
    order = {},
  }, M)
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
    self.total_weight = self.total_weight - self.weights[key]
  end
  local weight = math.max(0, self.weigh(value))
  if self.max_weight and weight > self.max_weight then
    self.values[key] = nil
    self.weights[key] = nil
    return false
  end
  self.values[key] = value
  self.weights[key] = weight
  self.total_weight = self.total_weight + weight
  self.order[#self.order + 1] = key
  while #self.order > self.capacity or (self.max_weight and self.total_weight > self.max_weight) do
    local oldest = table.remove(self.order, 1)
    self.total_weight = self.total_weight - self.weights[oldest]
    self.values[oldest] = nil
    self.weights[oldest] = nil
  end
  return true
end

function M:clear()
  self.values = {}
  self.weights = {}
  self.total_weight = 0
  self.order = {}
end

return M
