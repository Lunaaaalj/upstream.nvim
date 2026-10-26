-- Defaults, merged with setup() opts into M.options.

local M = {}

M.defaults = {
  -- ms before a `gh` call is killed, so a hung request never freezes anything
  timeout = 15000,
  -- items per page (GitHub caps GraphQL connections at 100)
  per_page = 50,
  -- tab opened the first time; afterwards the last tab is remembered
  tab = "issues",
  -- highlight overrides: { UpstreamTitle = { link = "Title" }, ... }
  highlights = {},
  -- float-local keys; set one to false to disable it
  keys = {
    next_tab = "<Tab>",
    prev_tab = "<S-Tab>",
    filter = "/",
    state = "s",
    refresh = "r",
    browser = "gx",
    focus = "<CR>",
    back = "<C-h>",
    scroll_down = "<C-d>",
    scroll_up = "<C-u>",
    help = "?",
    close = "q",
  },
  -- reserved for later phases (AI drafts / work on issue)
  ai = {
    command = "claude",
    open_chat = nil,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
