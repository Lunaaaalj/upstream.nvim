-- The GitHub float: a frame window (border, title with repo/branch/counts,
-- tab bar, pane separators, key hints) holding two borderless child floats,
-- the list (left) and the detail pane (right, filetype=markdown).
--
-- State (tab, per-tab state/filter/cursor/items) lives in `repos` and
-- survives close/reopen; `ui` only holds the handles of the open float.

local config = require("upstream.config")
local data = require("upstream.data")
local detail = require("upstream.ui.detail")
local hl = require("upstream.ui.hl")
local list = require("upstream.ui.list")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream")

local TABS = {
  { id = "issues", label = "Issues" },
  { id = "prs", label = "Pull requests" },
  { id = "reviews", label = "Review requests" },
  { id = "actions", label = "Actions" },
}

-- a tab is refetched on switch when its data is older than this (seconds)
local TAB_TTL = 60
-- a detail is refetched on selection when older than this (seconds)
local DETAIL_TTL = 60

local repos = {} -- repo.full -> { tab, views = { [tab] = view }, header }
local ui = {} -- handles of the open float
local fresh = {} -- "<repo>:<kind>-<n>" -> os.time() of the last fresh detail

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function valid_win(w) return w ~= nil and vim.api.nvim_win_is_valid(w) end

local function is_open() return valid_win(ui.frame) and valid_win(ui.list) end

local function ours(win)
  return win == ui.frame or win == ui.list or win == ui.detail or win == ui.input or win == ui.help
end

local function scratch()
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  return b
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- chunks { {text, hl?}, … } → line, spans { {col, end_col, hl} }
local function compose(chunks)
  local line, spans = "", {}
  for _, c in ipairs(chunks) do
    if c[2] then spans[#spans + 1] = { #line, #line + #c[1], c[2] } end
    line = line .. c[1]
  end
  return line, spans
end

local function mark(buf, row, spans)
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(buf, ns, row, s[1], { end_col = s[2], hl_group = s[3] })
  end
end

local function width(chunks)
  local w = 0
  for _, c in ipairs(chunks) do w = w + vim.fn.strdisplaywidth(c[1]) end
  return w
end

local function new_view()
  return { items = {}, filter = "", state = "open", cursor = 1, rows = {}, loaded = false, has_next = false, gen = 0 }
end

local function st() return repos[ui.repo.full] end
local function view() return st().views[st().tab] end

local function key_of(it) return type(it) == "table" and (it.kind .. "-" .. it.number) or nil end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local function render_title()
  if not is_open() then return end
  local r, h = ui.repo, st().header
  local left = { { " " .. r.full .. " ", "UpstreamTitle" } }
  if r.branch then
    left[#left + 1] = { "── ", "UpstreamBorder" }
    left[#left + 1] = { r.branch .. " ", "UpstreamMuted" }
  end
  local right = {}
  if h then
    right[#right + 1] = { (" %d %s · %d %s"):format(h.prs, h.prs == 1 and "PR" or "PRs",
      h.issues, h.issues == 1 and "issue" or "issues"), "UpstreamMuted" }
    local ck = h.ci and list.CHECKS[h.ci]
    if ck then
      right[#right + 1] = { " · ", "UpstreamMuted" }
      right[#right + 1] = { ck[1] .. " CI", ck[2] }
    end
    right[#right + 1] = { " ", "UpstreamMuted" }
  end
  local fill = ui.geo.iw - width(left) - width(right) - 1
  if fill < 1 then right, fill = {}, ui.geo.iw - width(left) - 1 end
  local title = vim.list_extend(left, { { string.rep("─", math.max(fill, 0)), "UpstreamBorder" } })
  vim.list_extend(title, right)
  vim.api.nvim_win_set_config(ui.frame, { title = title, title_pos = "left" })
end

-- row 0: tab bar (+ state/filter on the right); row 1: separator; then the
-- vertical line between the panes
local function render_frame()
  if not is_open() then return end
  local g, buf = ui.geo, ui.frame_buf
  local cur = st().tab
  local chunks = { { " " } }
  for i, t in ipairs(TABS) do
    local active = t.id == cur
    chunks[#chunks + 1] = { " " .. i .. " ", active and "UpstreamTabActive" or "UpstreamMuted" }
    chunks[#chunks + 1] = { t.label .. " ", active and "UpstreamTabActive" or "UpstreamTab" }
    chunks[#chunks + 1] = { "  " }
  end
  local bar, bar_spans = compose(chunks)
  local lines = { bar, string.rep("─", g.lw) .. "┬" .. string.rep("─", g.iw - g.lw - 1) }
  for _ = 3, g.ih do lines[#lines + 1] = string.rep(" ", g.lw) .. "│" end
  set_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  mark(buf, 0, bar_spans)
  vim.api.nvim_buf_set_extmark(buf, ns, 1, 0, { end_row = 2, end_col = 0, hl_group = "UpstreamBorder", hl_eol = true })
  for row = 2, g.ih - 1 do
    vim.api.nvim_buf_set_extmark(buf, ns, row, g.lw, { end_col = g.lw + #"│", hl_group = "UpstreamBorder" })
  end

  local v = view()
  local right = {}
  if v.filter ~= "" then
    right[#right + 1] = { "/" .. v.filter .. "  ", "UpstreamAccent" }
  else
    right[#right + 1] = { "/ filter  ", "UpstreamMuted" }
  end
  right[#right + 1] = { v.state .. " ", "UpstreamMuted" }
  if v.total then right[#right + 1] = { "· " .. v.total .. " ", "UpstreamMuted" } end
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = right, virt_text_pos = "right_align" })
end

local function render_list()
  if not is_open() then return end
  local v = view()
  local lines, spans, rows = list.render(v)
  v.rows = rows
  set_lines(ui.list_buf, lines)
  vim.api.nvim_buf_clear_namespace(ui.list_buf, ns, 0, -1)
  for _, s in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(ui.list_buf, ns, s[1], s[2], { end_col = s[3], hl_group = s[4] })
  end
  -- keep the cursor on the same item when the list reorders
  local row = math.min(math.max(v.cursor, 1), #lines)
  if v.sel_key then
    for i, it in pairs(rows) do
      if key_of(it) == v.sel_key then row = i break end
    end
  end
  vim.api.nvim_win_set_cursor(ui.list, { row, 0 })
  render_frame()
end

local function draw_detail(it)
  if not is_open() then return end
  local k = key_of(it)
  local lines = it and detail.lines(it) or { "" }
  local view_state = k == ui.shown_key and vim.api.nvim_win_call(ui.detail, vim.fn.winsaveview)
  set_lines(ui.detail_buf, lines)
  if view_state then
    vim.api.nvim_win_call(ui.detail, function() vim.fn.winrestview(view_state) end)
  else
    vim.api.nvim_win_set_cursor(ui.detail, { 1, 0 })
  end
  ui.shown_key = k
end

-- ---------------------------------------------------------------------------
-- data → ui
-- ---------------------------------------------------------------------------

local load_more

local function fetch_detail(it)
  if type(it) ~= "table" or it.kind == "run" then return end
  local k, repo = key_of(it), ui.repo
  local fk = repo.full .. ":" .. k
  if fresh[fk] and os.time() - fresh[fk] < DETAIL_TTL then return end
  data.detail(repo, it.kind, it.number, function(err, d, meta)
    if err or ui.want ~= k then return end
    if not meta.stale then fresh[fk] = os.time() end
    draw_detail(d)
  end)
end

-- Selection changed: draw what we have now (cache, else the list row), and
-- fetch the full item after a short debounce so j/k stay cheap.
local function on_cursor()
  if not is_open() then return end
  local v = view()
  local row = vim.api.nvim_win_get_cursor(ui.list)[1]
  local it = v.rows[row]
  v.cursor = row
  if it == "more" then return load_more() end
  if type(it) ~= "table" then
    ui.want = nil
    return draw_detail(nil)
  end
  local k = key_of(it)
  v.sel_key = k
  if k == ui.want then return end
  ui.want = k
  draw_detail(it.kind ~= "run" and require("upstream.cache").read(ui.repo, k) or it)
  ui.timer:stop()
  ui.timer:start(120, 0, vim.schedule_wrap(function()
    if ui.want == k then fetch_detail(it) end
  end))
end

local function load(force)
  local s = st()
  local tab, v = s.tab, s.views[s.tab]
  v.gen = v.gen + 1
  local gen = v.gen
  v.error = nil
  data.list(ui.repo, tab, v.state, nil, function(err, page, meta)
    if v.gen ~= gen then return end
    if err then
      v.error = err
    else
      v.items, v.has_next, v.next_cursor, v.total = page.items, page.has_next, page.cursor, page.total
      v.loaded = true
      if not meta.stale then v.fetched = os.time() end
    end
    if is_open() and st().tab == tab then
      render_list()
      on_cursor()
    end
  end, force)
end

function load_more()
  local s = st()
  local tab, v = s.tab, s.views[s.tab]
  if not v.has_next or v.loading_more then return end
  v.loading_more = true
  render_list()
  local gen = v.gen
  data.list(ui.repo, tab, v.state, v.next_cursor, function(err, page)
    if v.gen ~= gen then return end
    v.loading_more = false
    if not err then
      vim.list_extend(v.items, page.items)
      v.has_next, v.next_cursor = page.has_next, page.cursor
    end
    if is_open() and st().tab == tab then
      render_list()
      on_cursor()
    end
  end)
end

local function load_header(force)
  local repo = ui.repo
  data.header(repo, function(err, h)
    if err or not h then return end
    repos[repo.full].header = h
    if is_open() and ui.repo.full == repo.full then render_title() end
  end, force)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

local function set_tab(id)
  local s = st()
  s.tab = id
  ui.want = nil
  render_list()
  on_cursor()
  local v = view()
  if not v.loaded or not v.fetched or os.time() - v.fetched > TAB_TTL then load() end
end

local function cycle_tab(step)
  local cur = 1
  for i, t in ipairs(TABS) do
    if t.id == st().tab then cur = i end
  end
  set_tab(TABS[(cur - 1 + step) % #TABS + 1].id)
end

local function cycle_state()
  local v = view()
  local i = vim.fn.index(data.states, v.state) + 1
  v.state = data.states[i % #data.states + 1]
  v.items, v.loaded, v.has_next, v.next_cursor, v.total = {}, false, false, nil, nil
  v.cursor, v.sel_key = 1, nil
  ui.want = nil
  render_list()
  load()
end

local function refresh()
  fresh = {}
  ui.want = nil
  load(true)
  load_header(true)
end

local function selected()
  local row = vim.api.nvim_win_get_cursor(ui.list)[1]
  local it = view().rows[row]
  return type(it) == "table" and it or nil, it
end

local function browse()
  local it = vim.api.nvim_get_current_win() == ui.list and selected() or nil
  if not it and ui.shown_key then
    for _, x in ipairs(view().items) do
      if key_of(x) == ui.shown_key then it = x end
    end
  end
  local url = it and it.url or ui.repo.url
  if url then vim.ui.open(url) end
end

local function focus_detail()
  local _, raw = selected()
  if raw == "more" then return load_more() end
  if valid_win(ui.detail) then vim.api.nvim_set_current_win(ui.detail) end
end

local function focus_list()
  if valid_win(ui.list) then vim.api.nvim_set_current_win(ui.list) end
end

local function scroll_detail(key)
  if not valid_win(ui.detail) then return end
  vim.api.nvim_win_call(ui.detail, function()
    vim.cmd.normal({ args = { vim.keycode(key) }, bang = true })
  end)
end

local function close_input()
  local win = ui.input
  ui.input = nil
  focus_list()
  if valid_win(win) then vim.api.nvim_win_close(win, true) end
  vim.cmd.stopinsert()
end

-- a 1-line input over the right of the tab bar; filters live
local function filter()
  local v = view()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  local w = math.min(40, ui.geo.iw - 4)
  ui.input = vim.api.nvim_open_win(buf, true, {
    relative = "win", win = ui.frame, row = 0, col = ui.geo.iw - w - 1, width = w, height = 1,
    style = "minimal", zindex = 60,
  })
  vim.wo[ui.input].winhighlight = hl.winhl("Normal:UpstreamSel")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { v.filter })
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { virt_text = { { "/", "UpstreamAccent" } }, virt_text_pos = "inline" })
  vim.cmd.startinsert({ bang = true })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = buf,
    callback = function()
      v.filter = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
      v.cursor, v.sel_key = 1, nil
      render_list()
      on_cursor()
    end,
  })
  local o = { buffer = buf, nowait = true }
  vim.keymap.set({ "i", "n" }, "<CR>", close_input, o)
  vim.keymap.set({ "i", "n" }, "<Esc>", function()
    v.filter = ""
    close_input()
    render_list()
    on_cursor()
  end, o)
end

local function help()
  local k = config.options.keys
  local rows = {
    { "j / k / G", "move (G on “load more” loads the next page)" },
    { k.next_tab .. " / " .. k.prev_tab .. " / 1–4", "switch tab" },
    { k.focus, "focus the detail pane (" .. k.back .. " / q back)" },
    { k.scroll_down .. " / " .. k.scroll_up, "scroll the detail pane" },
    { k.filter, "filter (<Esc> clears)" },
    { k.state, "state: open → closed → all" },
    { k.refresh, "refresh" },
    { k.browser, "open in the browser" },
    { k.close .. " / <Esc>", "close" },
  }
  local lines = { "" }
  for _, r in ipairs(rows) do lines[#lines + 1] = ("  %-22s %s"):format(r[1], r[2]) end
  lines[#lines + 1] = ""
  local buf = scratch()
  set_lines(buf, lines)
  for i = 1, #rows do
    vim.api.nvim_buf_set_extmark(buf, ns, i, 2, { end_col = 24, hl_group = "UpstreamAccent" })
  end
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  w = w + 2
  ui.help = vim.api.nvim_open_win(buf, true, {
    relative = "editor", row = math.floor((vim.o.lines - #lines) / 2) - 1, col = math.floor((vim.o.columns - w) / 2),
    width = w, height = #lines, style = "minimal", border = "rounded", zindex = 70,
    title = " upstream keys ", title_pos = "center",
  })
  vim.wo[ui.help].winhighlight = hl.winhl()
  vim.wo[ui.help].winblend = 0
  local function close_help()
    local win = ui.help
    ui.help = nil
    focus_list()
    if valid_win(win) then vim.api.nvim_win_close(win, true) end
  end
  for _, key in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", key, close_help, { buffer = buf, nowait = true })
  end
end

-- ---------------------------------------------------------------------------
-- keymaps
-- ---------------------------------------------------------------------------

local function keymaps()
  local k = config.options.keys
  local function map(buf, lhs, fn)
    if lhs then vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true }) end
  end
  local lb, db = ui.list_buf, ui.detail_buf

  map(lb, k.next_tab, function() cycle_tab(1) end)
  map(lb, k.prev_tab, function() cycle_tab(-1) end)
  for i, t in ipairs(TABS) do map(lb, tostring(i), function() set_tab(t.id) end) end
  map(lb, k.filter, filter)
  map(lb, k.state, cycle_state)
  map(lb, k.refresh, refresh)
  map(lb, k.browser, browse)
  map(lb, k.focus, focus_detail)
  map(lb, k.scroll_down, function() scroll_detail("<C-d>") end)
  map(lb, k.scroll_up, function() scroll_detail("<C-u>") end)
  map(lb, k.help, help)
  map(lb, k.close, M.close)
  map(lb, "<Esc>", function()
    local v = view()
    if v.filter ~= "" then
      v.filter = ""
      render_list()
      on_cursor()
    else
      M.close()
    end
  end)

  map(db, k.back, focus_list)
  map(db, "q", focus_list)
  map(db, "<Esc>", focus_list)
  map(db, k.help, help)
  map(db, k.refresh, refresh)
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

local function geometry()
  local iw = vim.o.columns - 4
  local ih = vim.o.lines - vim.o.cmdheight - 4
  return { iw = iw, ih = ih, lw = math.max(28, math.floor(iw * 0.38)) }
end

local function hints()
  local k = config.options.keys
  return (" %s open · %s filter · %s state · %s refresh · %s web · %s help · %s close ")
    :format(k.focus, k.filter, k.state, k.refresh, k.browser, k.help, k.close)
end

local function build(repo, tab)
  local g = geometry()
  if g.iw < 60 or g.ih < 10 then
    return vim.notify("upstream: the editor is too small for the GitHub float", vim.log.levels.WARN)
  end
  hl.setup()
  ui = { repo = repo, geo = g, timer = vim.uv.new_timer() }
  repos[repo.full] = repos[repo.full] or { tab = config.options.tab, views = {} }
  local s = repos[repo.full]
  for _, t in ipairs(TABS) do s.views[t.id] = s.views[t.id] or new_view() end
  if tab then s.tab = tab end

  ui.frame_buf = scratch()
  ui.frame = vim.api.nvim_open_win(ui.frame_buf, false, {
    relative = "editor", row = 0, col = 1, width = g.iw, height = g.ih,
    style = "minimal", border = "rounded", focusable = false,
    title = " " .. repo.full .. " ", title_pos = "left",
    footer = { { hints(), "UpstreamMuted" } }, footer_pos = "center",
  })

  ui.list_buf = scratch()
  vim.bo[ui.list_buf].filetype = "upstream"
  ui.list = vim.api.nvim_open_win(ui.list_buf, true, {
    relative = "win", win = ui.frame, row = 2, col = 0, width = g.lw, height = g.ih - 2,
    style = "minimal", zindex = 51,
  })
  -- the cursorline is the selection marker
  vim.wo[ui.list].cursorline = true
  vim.wo[ui.list].cursorlineopt = "line"
  vim.wo[ui.list].wrap = false

  ui.detail_buf = scratch()
  vim.bo[ui.detail_buf].filetype = "markdown"
  pcall(vim.treesitter.start, ui.detail_buf, "markdown")
  ui.detail = vim.api.nvim_open_win(ui.detail_buf, false, {
    relative = "win", win = ui.frame, row = 2, col = g.lw + 2, width = g.iw - g.lw - 3, height = g.ih - 2,
    style = "minimal", zindex = 51,
  })
  vim.wo[ui.detail].wrap = true
  vim.wo[ui.detail].linebreak = true
  vim.wo[ui.detail].breakindent = true
  vim.wo[ui.detail].conceallevel = 2

  vim.wo[ui.frame].winhighlight = hl.winhl()
  vim.wo[ui.list].winhighlight = hl.winhl("CursorLine:UpstreamSel")
  vim.wo[ui.detail].winhighlight = hl.winhl()
  for _, w in ipairs({ ui.frame, ui.list, ui.detail }) do vim.wo[w].winblend = 0 end

  keymaps()
  ui.augroup = vim.api.nvim_create_augroup("upstream_ui", { clear = true })
  vim.api.nvim_create_autocmd("CursorMoved", { group = ui.augroup, buffer = ui.list_buf, callback = on_cursor })
  vim.api.nvim_create_autocmd("WinLeave", {
    group = ui.augroup,
    callback = function()
      vim.schedule(function()
        if ui.frame and not ours(vim.api.nvim_get_current_win()) then M.close() end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = ui.augroup,
    callback = function()
      M.close()
      M.open()
    end,
  })
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = ui.augroup,
    callback = function()
      hl.setup()
      render_title()
      render_list()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = ui.augroup,
    pattern = "UpstreamChanged",
    callback = function() render_frame() end,
  })

  render_title()
  render_list()
  on_cursor()
  load()
  load_header()
end

function M.is_open() return is_open() end

-- open({ tab = "issues"|"prs"|"reviews"|"actions" })
function M.open(opts)
  opts = opts or {}
  if is_open() then
    vim.api.nvim_set_current_win(ui.list)
    if opts.tab then set_tab(opts.tab) end
    return
  end
  require("upstream.repo").detect(function(err, repo)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    if is_open() then return end
    build(repo, opts.tab)
  end)
end

function M.close()
  if ui.timer then
    ui.timer:stop()
    ui.timer:close()
  end
  if ui.augroup then pcall(vim.api.nvim_del_augroup_by_id, ui.augroup) end
  -- by name, not ipairs: input/help are usually nil and would end the loop
  for _, name in ipairs({ "input", "help", "detail", "list", "frame" }) do
    if valid_win(ui[name]) then pcall(vim.api.nvim_win_close, ui[name], true) end
  end
  ui = {}
end

function M.toggle(opts)
  if is_open() then M.close() else M.open(opts) end
end

return M
