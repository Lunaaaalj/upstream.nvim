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

return M
