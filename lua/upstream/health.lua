-- :checkhealth upstream

local M = {}

local function version(cmd)
  local ok, res = pcall(function() return vim.system(cmd, { text = true, timeout = 5000 }):wait() end)
  if not ok or res.code ~= 0 then return nil end
  return vim.split(vim.trim(res.stdout or ""), "\n")[1]
end

function M.check()
  local h = vim.health
  h.start("upstream.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    h.ok("Neovim " .. tostring(vim.version()))
  else
    h.error("Neovim >= 0.10 is required")
  end

  if vim.fn.executable("gh") == 1 then
    h.ok("gh: " .. (version({ "gh", "--version" }) or "found"))
    local ok, res = pcall(function()
      return vim.system({ "gh", "auth", "status", "--hostname", "github.com" }, { text = true, timeout = 8000 }):wait()
    end)
    if ok and res.code == 0 then
      h.ok("gh is authenticated with github.com")
    else
      h.error("gh is not authenticated", { "Run `gh auth login`" })
    end
  else
    h.error("gh not found", { "Install the GitHub CLI: https://cli.github.com" })
  end

  if vim.fn.executable("git") == 1 then
    h.ok("git: " .. (version({ "git", "--version" }) or "found"))
  else
    h.error("git not found")
  end

  local ai = require("upstream.config").options.ai.command
  if vim.fn.executable(ai) == 1 then
    h.ok(ai .. ": " .. (version({ ai, "--version" }) or "found"))
  else
    h.warn(ai .. " not found", { "Only needed for the AI features (later phases)" })
  end
end

return M
