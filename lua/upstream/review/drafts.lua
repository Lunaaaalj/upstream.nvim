-- AI review drafts list: a float over the review tab. Each finding is accepted
-- as-is (a), edited in a compose buffer first (e), or dropped (d). Accepted
-- drafts become comments in your *pending* review; nothing is published
-- until you submit the review (S in the diff).

local compose = require("upstream.compose")
local hl = require("upstream.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream_drafts")

local SEV = { high = "UpstreamClosed", medium = "UpstreamPending", low = "UpstreamAccent", nit = "UpstreamMuted" }

local function where(d)
  local a = d.anchor
  if a.subject_type == "FILE" then return a.path end
  return ("%s:%s%d"):format(a.path, a.start_line and (a.start_line .. "–") or "", a.line)
end

function M.open(R)
  local review = require("upstream.review")
  if #R.drafts == 0 then return vim.notify("upstream: no AI drafts (A runs the review assist)", vim.log.levels.INFO) end
  if R.drafts_win and vim.api.nvim_win_is_valid(R.drafts_win) then
    return vim.api.nvim_set_current_win(R.drafts_win)
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w = math.min(110, vim.o.columns - 6)
  local h = math.min(#R.drafts + 2, math.floor(vim.o.lines * 0.4))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = vim.o.lines - h - 4, col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, style = "minimal", border = "rounded", zindex = 60,
    title = " AI review drafts ", title_pos = "center",
    footer = { { " a accept · e edit · d drop · <CR> show in diff · K read · q close ", "UpstreamMuted" } },
    footer_pos = "center",
  })
  R.drafts_win = win
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = hl.winhl("CursorLine:UpstreamSel")

  local function render()
    if not vim.api.nvim_buf_is_valid(buf) then return end
    if #R.drafts == 0 then
      pcall(vim.api.nvim_win_close, win, true)
      return vim.notify("upstream: all drafts handled; S submits the review", vim.log.levels.INFO)
    end
    local lines = {}
    for i, d in ipairs(R.drafts) do
      local first = (d.body:gsub("%s+", " "))
      lines[i] = (" %-6s %-34s %s"):format(d.severity, where(d):sub(1, 34), first)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, d in ipairs(R.drafts) do
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 7, hl_group = SEV[d.severity] or "UpstreamMuted" })
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 8, { end_col = 42, hl_group = "UpstreamAccent" })
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_height(win, math.min(#R.drafts, math.floor(vim.o.lines * 0.4)))
    end
  end
  render()

  local function current()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return R.drafts[row], row
  end
  local function remove(d)
    for i, x in ipairs(R.drafts) do
      if x == d then table.remove(R.drafts, i) break end
    end
    review.render(R)
    render()
  end
  local function close() pcall(vim.api.nvim_win_close, win, true) end

  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "a", function()
    local d = current()
    if not d or d.busy then return end
    d.busy = true
    review.add_thread(R, d.anchor, d.body, function(err)
      d.busy = false
      if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
      remove(d)
    end)
  end, o)
  vim.keymap.set("n", "d", function()
    local d = current()
    if d then remove(d) end
  end, o)
  vim.keymap.set("n", "e", function()
    local d = current()
    if not d then return end
    close()
    if vim.api.nvim_win_is_valid(R.win) then vim.api.nvim_set_current_win(R.win) end
    compose.open(R.repo, {
      key = ("pr-%d-draft-%s"):format(R.number, where(d)),
      title = "AI draft on " .. where(d),
      body = d.body,
      split = true,
      submit = function(_, body, done)
        if body == "" then return done("the comment is empty") end
        review.add_thread(R, d.anchor, body, done)
      end,
      on_done = function()
        remove(d)
        if vim.api.nvim_win_is_valid(R.win) then vim.api.nvim_set_current_win(R.win) end
        if #R.drafts > 0 then M.open(R) end
      end,
    })
  end, o)
  vim.keymap.set("n", "<CR>", function()
    local d = current()
    if not d or not d.row then return end
    close()
    if vim.api.nvim_win_is_valid(R.win) then
      vim.api.nvim_set_current_win(R.win)
      vim.api.nvim_win_set_cursor(R.win, { d.row, 0 })
      vim.cmd("normal! zz")
    end
  end, o)
  vim.keymap.set("n", "K", function()
    local d = current()
    if not d then return end
    review.show(R, { { path = d.anchor.path, line = d.anchor.line, comments = {
      { author = "AI draft (" .. d.severity .. ")", body = d.body, at = nil },
    } } })
  end, o)
  for _, k in ipairs({ "q", "<Esc>" }) do vim.keymap.set("n", k, close, o) end
end

return M
