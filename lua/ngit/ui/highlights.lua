local M = {}

local linked_definitions = {
  NgitHeader = { link = "Title" },
  NgitPanelActive = { link = "Title" },
  NgitSection = { link = "Special" },
  NgitStaged = { link = "DiffAdd" },
  NgitUnstaged = { link = "DiffChange" },
  NgitUntracked = { link = "DiagnosticInfo" },
  NgitConflict = { link = "DiagnosticError" },
  NgitSuccess = { link = "DiagnosticOk" },
  NgitFailure = { link = "DiagnosticError" },
  NgitDiffFiller = { link = "NonText" },
  NgitDiffHeader = { link = "Title" },
  NgitCommitHash = { link = "Number" },
  NgitCommitType = { link = "Type" },
  NgitDate = { link = "Comment" },
  NgitDecoration = { link = "Special" },
  NgitBranchLocal = { link = "Function" },
  NgitBranchRemote = { link = "Identifier" },
  NgitUpstream = { link = "Comment" },
  NgitStashRef = { link = "Label" },
  NgitPath = { link = "Directory" },
  NgitStatusline = { link = "StatusLineNC" },
  NgitMuted = { link = "Comment" },
}

local function color(name, attribute, fallback)
  local ok, highlight = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and highlight[attribute] then
    return highlight[attribute]
  end
  return fallback
end

local function blend(background, foreground, amount)
  local function channel(shift)
    local base = bit.band(bit.rshift(background, shift), 0xff)
    local accent = bit.band(bit.rshift(foreground, shift), 0xff)
    return math.floor(base + (accent - base) * amount + 0.5)
  end
  return bit.lshift(channel(16), 16) + bit.lshift(channel(8), 8) + channel(0)
end

local function derived_definitions()
  local fallback_background = vim.o.background == "light" and 0xf5f5f5 or 0x101014
  local background = color("Normal", "bg", fallback_background)
  local red = color("DiagnosticError", "fg", color("DiffDelete", "fg", 0xff5f67))
  local green = color("DiagnosticOk", "fg", color("DiffAdd", "fg", 0x55d66b))
  local yellow = color("DiagnosticWarn", "fg", color("DiffChange", "fg", 0xe5b95c))
  local line_amount = vim.o.background == "light" and 0.2 or 0.3
  local text_amount = vim.o.background == "light" and 0.38 or 0.52
  return {
    NgitDiffAdd = { bg = blend(background, green, line_amount) },
    NgitDiffDelete = { bg = blend(background, red, line_amount) },
    NgitDiffChange = { bg = blend(background, yellow, line_amount) },
    NgitDiffAddNumber = {
      fg = green,
      bg = blend(background, green, line_amount),
      bold = true,
    },
    NgitDiffDeleteNumber = {
      fg = red,
      bg = blend(background, red, line_amount),
      bold = true,
    },
    NgitDiffAddText = { bg = blend(background, green, text_amount), bold = true },
    NgitDiffDeleteText = { bg = blend(background, red, text_amount), bold = true },
    NgitDiffText = { bg = blend(background, yellow, text_amount), bold = true },
  }
end

local function apply()
  for name, spec in pairs(linked_definitions) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
  end
  for name, spec in pairs(derived_definitions()) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
  end
end

function M.setup()
  apply()
  local group = vim.api.nvim_create_augroup("ngit_highlights", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = apply,
  })
end

return M
