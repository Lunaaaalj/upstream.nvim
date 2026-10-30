-- A small picker float for labels / assignees / reviewers / milestones.
-- vim.ui.select can't multi-select, and the usual pickers open a normal
-- window, which would close the GitHub float (it closes when focus leaves).
-- This one is marked `b:upstream_overlay`, so the float treats it as its own.
--
--   pick.open({ title = "Labels", multi = true, items = {
--     { label = "bug", desc = "Something isn't working", selected = true, value = <any> },
--   } }, function(chosen) end)   -- chosen = { item, … } (multi) / item (single); nil = cancelled

local hl = require("upstream.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream_pick")

function M.open(opts, cb)
  local items = opts.items or {}
  if #items == 0 then
    vim.notify("upstream: nothing to choose from", vim.log.levels.INFO)
    return cb(nil)
  end
  local prev = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.b[buf].upstream_overlay = true

  local function render()
    local lines = {}
    for i, it in ipairs(items) do
      local box = opts.multi and (it.selected and "[x] " or "[ ] ") or ""
      lines[i] = " " .. box .. it.label .. (it.desc and it.desc ~= "" and ("  " .. it.desc) or "")
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    for i, it in ipairs(items) do
      local box = opts.multi and 4 or 0
      if opts.multi and it.selected then
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 1, { end_col = 4, hl_group = "UpstreamOpen" })
      end
      if it.desc and it.desc ~= "" then
        local s = 1 + box + #it.label + 2
        vim.api.nvim_buf_set_extmark(buf, ns, i - 1, s, { end_col = s + #it.desc, hl_group = "UpstreamMuted" })
      end
    end
  end
  render()

  local w = 24
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do w = math.max(w, vim.fn.strdisplaywidth(l) + 2) end
  w = math.min(w, math.floor(vim.o.columns * 0.6))
  local h = math.min(#items, math.floor(vim.o.lines * 0.6))
  local hint = opts.multi and " <Space> toggle · <CR> apply · q cancel " or " <CR> choose · q cancel "
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - h) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, style = "minimal", border = "rounded", zindex = 80,
    title = " " .. (opts.title or "Choose") .. " ", title_pos = "center",
    footer = { { hint, "UpstreamMuted" } }, footer_pos = "center",
  })
  vim.wo[win].winhighlight = hl.winhl("CursorLine:UpstreamSel")
  vim.wo[win].cursorline = true
  vim.wo[win].winblend = 0
  vim.wo[win].wrap = false

  local done = false
  local function finish(result)
    if done then return end
    done = true
    if vim.api.nvim_win_is_valid(prev) then pcall(vim.api.nvim_set_current_win, prev) end
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    cb(result)
  end

  local function toggle()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    items[row].selected = not items[row].selected
    render()
    vim.api.nvim_win_set_cursor(win, { math.min(row + 1, #items), 0 })
  end

  local o = { buffer = buf, nowait = true, silent = true }
  if opts.multi then
    vim.keymap.set("n", "<Space>", toggle, o)
    vim.keymap.set("n", "<Tab>", toggle, o)
    vim.keymap.set("n", "<CR>", function()
      finish(vim.tbl_filter(function(it) return it.selected end, items))
    end, o)
  else
    vim.keymap.set("n", "<CR>", function() finish(items[vim.api.nvim_win_get_cursor(win)[1]]) end, o)
  end
  for _, k in ipairs({ "q", "<Esc>" }) do vim.keymap.set("n", k, function() finish(nil) end, o) end
  vim.api.nvim_create_autocmd("WinLeave", { buffer = buf, once = true, callback = function()
    vim.schedule(function() finish(nil) end)
  end })
end

return M
