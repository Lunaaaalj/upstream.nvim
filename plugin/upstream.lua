-- :Upstream [issues|prs|reviews|actions]   open the float (on a tab)
-- :Upstream new-issue | new-pr | draft-pr  compose (draft-pr: AI title/body)
-- :Upstream review <number> [assist]       review a PR (assist: AI drafts)
-- Nothing else runs at startup.

if vim.g.loaded_upstream then return end
vim.g.loaded_upstream = true

local tabs = { "issues", "prs", "reviews", "actions" }
local subs = { "new-issue", "new-pr", "draft-pr", "review" }

vim.api.nvim_create_user_command("Upstream", function(cmd)
  local a, b, c = cmd.fargs[1], cmd.fargs[2], cmd.fargs[3]
  local up = require("upstream")
  if a == "new-issue" then return up.new_issue() end
  if a == "new-pr" then return up.new_pr() end
  if a == "draft-pr" then return up.new_pr({ ai = true }) end
  if a == "review" then
    local n = tonumber(b)
    if not n then return vim.notify("upstream: :Upstream review <number> [assist]", vim.log.levels.ERROR) end
    return up.review(n, { assist = c == "assist" })
  end
  if a and not vim.tbl_contains(tabs, a) then
    return vim.notify("upstream: unknown argument '" .. a .. "'", vim.log.levels.ERROR)
  end
  up.open({ tab = a })
end, {
  nargs = "*",
  desc = "GitHub float, compose, review",
  complete = function(lead, line)
    local n = #vim.split(line, "%s+", { trimempty = false })
    local pool = n <= 2 and vim.list_extend(vim.deepcopy(tabs), subs) or (n == 4 and { "assist" } or {})
    return vim.tbl_filter(function(t) return t:find(lead, 1, true) == 1 end, pool)
  end,
})
