-- :Upstream [issues|prs|reviews|actions]. Nothing else runs at startup.

if vim.g.loaded_upstream then return end
vim.g.loaded_upstream = true

local tabs = { "issues", "prs", "reviews", "actions" }

vim.api.nvim_create_user_command("Upstream", function(cmd)
  local tab = cmd.fargs[1]
  if tab and not vim.tbl_contains(tabs, tab) then
    return vim.notify("upstream: unknown tab '" .. tab .. "'", vim.log.levels.ERROR)
  end
  require("upstream").open({ tab = tab })
end, {
  nargs = "?",
  desc = "Open the GitHub float",
  complete = function(lead)
    return vim.tbl_filter(function(t) return t:find(lead, 1, true) == 1 end, tabs)
  end,
})
