-- Defaults, merged with setup() opts into M.options.

local M = {}

M.defaults = {
  -- ms before a `gh` call is killed, so a hung request never freezes anything
  timeout = 15000,
  -- items per page (GitHub caps GraphQL connections at 100)
  per_page = 50,
  -- tab opened the first time; afterwards the last tab is remembered
  tab = "issues",
  -- where compose buffers (comments, edits, new issues/PRs) open:
  -- "current" window, "split", "vsplit" or "tab". The review view always
  -- uses a split so the diff stays visible.
  compose = "current",
  -- local branch for "work on this issue": a template ({number}, {slug},
  -- {title}) or function(issue) -> name
  issue_branch = "{number}-{slug}",
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
    -- manage (issues / PRs)
    comment = "c",
    edit = "e",
    toggle_state = "x",
    labels = "l",
    assignees = "a",
    reviewers = "v",
    milestone = "M",
    merge = "m",
    checkout = "o",
    new = "n",
    configure = "C",
    work_on = "w",
    review = "R",
    ai = "A",
    -- Actions tab (on a run: R re-runs, x cancels)
    logs = "L",
  },
  -- AI drafts through headless Claude Code (`<command> -p --output-format json`)
  ai = {
    command = "claude",
    -- extra CLI args for the headless runs, e.g. { "--model", "sonnet" }
    args = {},
    -- ms; reviews of big PRs take a while
    timeout = 300000,
    -- upper bound on review-assist findings per run
    max_findings = 15,
    -- function(prompt, ctx) that starts an interactive chat seeded with
    -- `prompt` ("work on this issue"); ctx = { repo, number, kind, title, url }.
    -- nil = `:tabnew` + `:terminal <command> <prompt>`
    open_chat = nil,
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
