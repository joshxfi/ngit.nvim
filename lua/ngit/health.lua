local M = {}

function M.check()
  vim.health.start("ngit")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required")
  end

  if vim.fn.executable("git") == 1 then
    local result = vim.system({ "git", "--version" }, { text = true }):wait(2000)
    if result.code == 0 then
      vim.health.ok(vim.trim(result.stdout))
    else
      vim.health.error("Unable to execute Git")
    end
  else
    vim.health.error("Git was not found in PATH")
  end

  local ok, err = pcall(function()
    require("ngit.config").setup(require("ngit.config").get())
  end)
  if ok then
    vim.health.ok("Configuration is valid")
  else
    vim.health.error("Invalid configuration: " .. tostring(err))
  end
end

return M
