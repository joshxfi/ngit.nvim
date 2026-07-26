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

for command, view in pairs({
  NGitLog = "commits",
  NGitBranches = "branches",
  NGitStashes = "stashes",
}) do
  local selected_view = view
  vim.api.nvim_create_user_command(command, function()
    require("ngit").open({ view = selected_view })
  end, {
    desc = ("Open the ngit %s view"):format(selected_view),
  })
end

vim.api.nvim_create_user_command("NGitReview", function(command)
  require("ngit").review(command.args ~= "" and command.args or nil)
end, {
  desc = "Review a revision range, or this branch against its upstream",
  nargs = "?",
})

vim.api.nvim_create_user_command("NGitBlame", function(command)
  require("ngit").blame(command.args ~= "" and vim.fn.expand(command.args) or nil)
end, {
  desc = "Blame a file, or the current buffer",
  nargs = "?",
  complete = "file",
})

vim.api.nvim_create_user_command("NGitHistory", function(command)
  require("ngit").history(command.args ~= "" and command.args or nil)
end, {
  desc = "Follow one file's history, or the current buffer's",
  nargs = "?",
  complete = "file",
})
