local M = {}

local definitions = {
  NgitHeader = { link = "Title" },
  NgitSection = { link = "Special" },
  NgitStaged = { link = "DiffAdd" },
  NgitUnstaged = { link = "DiffChange" },
  NgitUntracked = { link = "DiagnosticInfo" },
  NgitConflict = { link = "DiagnosticError" },
  NgitMuted = { link = "Comment" },
}

function M.setup()
  for name, spec in pairs(definitions) do
    vim.api.nvim_set_hl(0, name, vim.tbl_extend("force", { default = true }, spec))
  end
end

return M
