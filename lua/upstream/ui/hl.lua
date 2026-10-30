-- Highlight groups. All are `default` links, so a colorscheme or the user's
-- config (setup({ highlights = … }) or plain :hi on ColorScheme) wins.

local config = require("upstream.config")

local M = {}

M.links = {
  UpstreamNormal = "NormalFloat",
  UpstreamBorder = "FloatBorder",
  UpstreamTitle = "Function",
  UpstreamMuted = "Comment",
  UpstreamAccent = "Function",
  UpstreamTab = "Comment",
  UpstreamTabActive = "Function",
  UpstreamSel = "CursorLine",
  UpstreamOpen = "DiagnosticOk",
  UpstreamClosed = "DiagnosticError",
  UpstreamMerged = "Constant",
  UpstreamDraft = "Comment",
  UpstreamPending = "DiagnosticWarn",
  UpstreamLabel = "Special",
  UpstreamNumber = "Number",
  -- review diff
  UpstreamDiffAdd = "DiffAdd",
  UpstreamDiffDelete = "DiffDelete",
  UpstreamDiffHunk = "Comment",
  UpstreamDiffFile = "Title",
  UpstreamLineNr = "LineNr",
  UpstreamDraftAI = "DiagnosticHint",
}

function M.setup()
  for name, target in pairs(M.links) do
    vim.api.nvim_set_hl(0, name, { link = target, default = true })
  end
  -- transparent variant: the float's text colour, no background
  local normal = vim.api.nvim_get_hl(0, { name = "UpstreamNormal", link = false })
  vim.api.nvim_set_hl(0, "UpstreamNormalTransparent", { fg = normal.fg, bg = "NONE" })
  for name, spec in pairs(config.options.highlights or {}) do
    vim.api.nvim_set_hl(0, name, spec)
  end
end

-- winhighlight for every upstream window; respects vim.g.ui_transparent
function M.winhl(extra)
  local normal = vim.g.ui_transparent and "UpstreamNormalTransparent" or "UpstreamNormal"
  local s = ("Normal:%s,NormalFloat:%s,NormalNC:%s,FloatBorder:UpstreamBorder,FloatTitle:UpstreamTitle,FloatFooter:UpstreamMuted")
    :format(normal, normal, normal)
  return extra and (s .. "," .. extra) or s
end

return M
