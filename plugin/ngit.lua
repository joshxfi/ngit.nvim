if vim.g.loaded_ngit == 1 then
  return
end
vim.g.loaded_ngit = 1

vim.api.nvim_create_user_command("NGit", function(command)
  require("ngit").open({
    cwd = command.args ~= "" and vim.fn.expand(command.args) or nil,
  })
end, {
  desc = "Open ngit for the current repository",
  nargs = "?",
  complete = "dir",
})

vim.api.nvim_create_user_command("NGitClose", function()
  require("ngit").close()
end, {
  desc = "Close the current ngit view",
})

vim.api.nvim_create_user_command("NGitRefresh", function()
  require("ngit").refresh()
end, {
  desc = "Refresh the current ngit view",
})

