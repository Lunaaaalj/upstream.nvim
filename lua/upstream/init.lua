-- upstream.nvim: a full-screen GitHub UI on top of the `gh` CLI.
--
--   require("upstream").setup({ ... })   -- optional; see config.lua
--   require("upstream").open({ tab = "prs" })

local M = {}

function M.setup(opts)
  require("upstream.config").setup(opts)
  require("upstream.ui.hl").setup()
end

function M.open(opts) require("upstream.ui").open(opts) end

function M.close() require("upstream.ui").close() end

function M.toggle(opts) require("upstream.ui").toggle(opts) end

local function with_repo(fn)
  require("upstream.repo").detect(function(err, repo)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    fn(repo)
  end)
end

-- new_issue() — compose a new issue
function M.new_issue() with_repo(function(repo) require("upstream.actions").new_issue(repo) end) end

-- new_pr({ ai = true, draft = false }) — compose a PR from the current
-- branch; `ai` has Claude draft the title and body first
function M.new_pr(opts) with_repo(function(repo) require("upstream.actions").new_pr(repo, opts) end) end

-- review(number, { assist = true }) — open the review tab for a PR
function M.review(number, opts)
  with_repo(function(repo) require("upstream.review").open(repo, number, opts) end)
end

return M
