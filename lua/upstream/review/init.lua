-- PR review in its own tabpage: the `base...head` diff as one unified buffer,
-- existing threads drawn as virt_lines under their line, and a pending review
-- that collects your comments until you submit (approve / comment / request
-- changes).
--
-- Every buffer row knows its anchor (rows[lnum] = { kind = "line", path, side,
-- line, hunk } / { kind = "file", path } / …), so a cursor position or a
-- visual range turns straight into GitHub's path / line / side / start_line.
-- Anchors are checked against the hunks before anything is sent (diff.valid).
--
-- AI review assist (A) drafts findings into a drafts list (ui: drafts.lua);
-- accepted drafts become pending comments like any other.

local ai = require("upstream.ai")
local compose = require("upstream.compose")
local data = require("upstream.data")
local diff = require("upstream.review.diff")
local gh = require("upstream.gh")
local hl = require("upstream.ui.hl")
local queries = require("upstream.queries")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream_review")
local reviews = {} -- bufnr -> review state

local function ago(iso) return require("upstream.ui.detail").ago(iso) end
local function err_notify(e) vim.notify("upstream: " .. e, vim.log.levels.ERROR) end
local function info(msg) vim.notify("upstream: " .. msg, vim.log.levels.INFO) end

local function akey(path, side, line) return path .. "\0" .. side .. "\0" .. tostring(line) end

-- ---------------------------------------------------------------------------
-- data
-- ---------------------------------------------------------------------------

local function norm_comment(c)
  return {
    id = c.id, author = vim.tbl_get(c, "author", "login") or "ghost", body = c.body or "",
    at = c.createdAt, pending = c.state == "PENDING",
  }
end

local function norm_thread(t)
  local comments = {}
  for _, c in ipairs(vim.tbl_get(t, "comments", "nodes") or {}) do comments[#comments + 1] = norm_comment(c) end
  return {
    id = t.id, resolved = t.isResolved, outdated = t.isOutdated, path = t.path,
    line = t.line, start_line = t.startLine, side = t.diffSide or "RIGHT", start_side = t.startDiffSide,
    original_line = t.originalLine, file_level = t.subjectType == "FILE", comments = comments,
  }
end

local function fetch(R, cb)
  local left, failed = 2, nil
  local function step(e)
    if e and not failed then failed = e end
    left = left - 1
    if left == 0 then cb(failed) end
  end
  gh.run({ "pr", "diff", tostring(R.number), "-R", R.repo.full, "--color", "never" }, function(e, out)
    if not e then
      R.files = diff.parse(out)
      R.idx = diff.index(R.files)
    end
    step(e)
  end, { timeout = 60000 })
  gh.graphql(queries.review, { owner = R.repo.owner, name = R.repo.name, number = R.number }, function(e, d)
    if not e then
      local pr = vim.tbl_get(d or {}, "repository", "pullRequest")
      if not pr then return step("PR #" .. R.number .. " not found") end
      R.viewer = vim.tbl_get(d, "viewer", "login")
      R.pr = pr
      R.threads = vim.tbl_map(norm_thread, vim.tbl_get(pr, "reviewThreads", "nodes") or {})
      R.pending = vim.tbl_get(pr, "pending", "nodes", 1)
    end
    step(e)
  end)
end

-- ---------------------------------------------------------------------------
-- rendering
-- ---------------------------------------------------------------------------

local function wrap(text, width)
  local out = {}
  for _, para in ipairs(vim.split((text or ""):gsub("\r", ""):gsub("\t", "  "), "\n", { plain = true })) do
    if para == "" then
      out[#out + 1] = ""
    else
      while vim.fn.strdisplaywidth(para) > width do
        local cut = width
        local sp = para:sub(1, width):match(".*()%s")
        if sp and sp > width / 2 then cut = sp end
        out[#out + 1] = para:sub(1, cut)
        para = para:sub(cut + 1)
      end
      out[#out + 1] = para
    end
  end
  return out
end

local MAX_BODY = 8

local function thread_virt(t, width)
  local bar = t.resolved and "UpstreamMuted" or "UpstreamAccent"
  local pend = false
  for _, c in ipairs(t.comments) do pend = pend or c.pending end
  if pend then bar = "UpstreamPending" end
  local first = t.comments[1] or { author = "?", body = "" }
  local vl = {}
  if t.resolved then
    local summary = (first.body:gsub("%s+", " ")):sub(1, width - 30)
    vl[#vl + 1] = { { "      ┃ ", bar }, { "✓ resolved · ", "UpstreamMuted" },
      { first.author .. ": " .. summary, "UpstreamMuted" } }
    return vl
  end
  for i, c in ipairs(t.comments) do
    local head = { { "      ┃ ", bar }, { (i > 1 and "↳ " or "") .. c.author, "UpstreamAccent" },
      { " · " .. ago(c.at), "UpstreamMuted" } }
    if c.pending then head[#head + 1] = { "  pending", "UpstreamPending" } end
    if i == 1 and t.start_line and t.start_line ~= t.line then
      head[#head + 1] = { ("  lines %d–%d"):format(t.start_line, t.line), "UpstreamMuted" }
    end
    vl[#vl + 1] = head
    local body = wrap(c.body, width - 10)
    for j, l in ipairs(body) do
      if j > MAX_BODY then
        vl[#vl + 1] = { { "      ┃ ", bar }, { "… K reads the whole thread", "UpstreamMuted" } }
        break
      end
      vl[#vl + 1] = { { "      ┃ ", bar }, { l } }
    end
  end
  return vl
end

local SEV = { high = "UpstreamClosed", medium = "UpstreamPending", low = "UpstreamAccent", nit = "UpstreamMuted" }

local function draft_virt(d, width)
  local vl = { { { "      ┃ ", "UpstreamDraftAI" }, { "✦ AI draft", "UpstreamDraftAI" },
    { " [" .. d.severity .. "]", SEV[d.severity] or "UpstreamMuted" },
    { "  gd: accept / edit / drop", "UpstreamMuted" } } }
  for j, l in ipairs(wrap(d.body, width - 10)) do
    if j > 4 then
      vl[#vl + 1] = { { "      ┃ ", "UpstreamDraftAI" }, { "…", "UpstreamMuted" } }
      break
    end
    vl[#vl + 1] = { { "      ┃ ", "UpstreamDraftAI" }, { l, "UpstreamMuted" } }
  end
  return vl
end

local STATUS = { added = "A", deleted = "D", renamed = "R", modified = "M" }

local function render(R)
  local buf = R.buf
  if not vim.api.nvim_buf_is_valid(buf) then return end
  local lines, rows, marks = {}, {}, {}
  local anchors, file_rows = {}, {}
  local function add(text, ri, mk)
    lines[#lines + 1] = text
    rows[#lines] = ri
    if mk then marks[#lines] = mk end
  end

  local pr = R.pr or {}
  local adds, dels = 0, 0
  for _, f in ipairs(R.files) do adds, dels = adds + f.additions, dels + f.deletions end
  local open_t, resolved_t, pending_c, outdated_t = 0, 0, 0, 0
  for _, t in ipairs(R.threads) do
    if t.resolved then resolved_t = resolved_t + 1 else open_t = open_t + 1 end
    if t.outdated and not t.file_level then outdated_t = outdated_t + 1 end
    for _, c in ipairs(t.comments) do
      if c.pending then pending_c = pending_c + 1 end
    end
  end
  add(("PR #%d %s"):format(R.number, pr.title or ""), { kind = "title" }, { line_hl = "UpstreamTitle" })
  local summary = ("%d files · +%d −%d · %d open / %d resolved threads"):format(#R.files, adds, dels, open_t, resolved_t)
  if outdated_t > 0 then summary = summary .. (" (%d outdated: T)"):format(outdated_t) end
  if R.pending then summary = summary .. (" · pending review: %d comment%s"):format(pending_c, pending_c == 1 and "" or "s") end
  if #R.drafts > 0 then summary = summary .. (" · %d AI drafts (gd)"):format(#R.drafts) end
  add(summary, { kind = "title" }, { line_hl = "UpstreamMuted" })
  add("c comment · r reply · x resolve · ]t [t threads · S submit · A AI assist · ? help", { kind = "title" },
    { line_hl = "UpstreamMuted" })
  add("", nil)

  for fi, f in ipairs(R.files) do
    add(("%s %s%s  +%d −%d"):format(STATUS[f.status] or "M", f.path,
      f.status == "renamed" and (" ← " .. f.old_path) or "", f.additions, f.deletions),
      { kind = "file", path = f.path, file = fi }, { line_hl = "UpstreamDiffFile" })
    file_rows[f.path] = #lines
    if f.binary then add("  (binary file)", { kind = "file", path = f.path, file = fi }, { line_hl = "UpstreamMuted" }) end
    for hi, h in ipairs(f.hunks) do
      add(h.header, { kind = "hunk", path = f.path, file = fi }, { line_hl = "UpstreamDiffHunk" })
      for _, l in ipairs(h.lines) do
        local side = l.kind == "-" and "LEFT" or "RIGHT"
        local ln = l.kind == "-" and l.old or l.new
        add(l.kind .. l.text, {
          kind = "line", path = f.path, file = fi, side = side, line = ln, hunk = fi .. ":" .. hi,
          old = l.old, new = l.new,
        }, {
          line_hl = l.kind == "+" and "UpstreamDiffAdd" or l.kind == "-" and "UpstreamDiffDelete" or nil,
          nr = ("%4s %4s "):format(l.old or "", l.new or ""),
        })
        anchors[akey(f.path, side, ln)] = #lines
        if l.kind == " " then anchors[akey(f.path, "LEFT", l.old)] = #lines end
      end
    end
    add("", nil)
  end
  if #R.files == 0 then add("(no changes)", nil) end

  -- place threads and drafts
  local at, unanchored = {}, {}
  local function place(row, entry)
    at[row] = at[row] or {}
    table.insert(at[row], entry)
  end
  for _, t in ipairs(R.threads) do
    local row
    if t.file_level then
      row = file_rows[t.path]
    elseif t.line and not t.outdated then
      row = anchors[akey(t.path, t.side, t.line)]
    end
    if row then place(row, { thread = t }) else unanchored[#unanchored + 1] = t end
  end
  for _, d in ipairs(R.drafts) do
    local row = d.anchor.subject_type == "FILE" and file_rows[d.anchor.path]
      or anchors[akey(d.anchor.path, d.anchor.side, d.anchor.line)]
    if row then place(row, { draft = d }) end
    d.row = row
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  local width = R.win and vim.api.nvim_win_is_valid(R.win) and vim.api.nvim_win_get_width(R.win) or 100
  for row, mk in pairs(marks) do
    local o = { line_hl_group = mk.line_hl }
    if mk.nr then
      o.virt_text = { { mk.nr, "UpstreamLineNr" } }
      o.virt_text_pos = "inline"
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, o)
  end
  local thread_rows = {}
  for row, list in pairs(at) do
    local vl = {}
    for _, e in ipairs(list) do
      vim.list_extend(vl, e.thread and thread_virt(e.thread, width) or draft_virt(e.draft, width))
    end
    vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, { virt_lines = vl })
    thread_rows[#thread_rows + 1] = row
  end
  table.sort(thread_rows)
  R.rows, R.at, R.unanchored, R.thread_rows, R.anchors, R.file_rows = rows, at, unanchored, thread_rows, anchors, file_rows
end

-- ---------------------------------------------------------------------------
-- pending review + threads
-- ---------------------------------------------------------------------------

local function ensure_pending(R, cb)
  if R.pending then return cb(nil, R.pending.id) end
  gh.graphql(queries.start_review, { pr = R.pr.id, oid = R.pr.headRefOid }, function(e, d)
    if e then return cb(e) end
    local id = vim.tbl_get(d or {}, "addPullRequestReview", "pullRequestReview", "id")
    if not id then return cb("could not start a review") end
    R.pending = { id = id }
    cb(nil, id)
  end)
end

-- anchor = { path, side, line, start_line?, start_side?, subject_type? }
function M.add_thread(R, anchor, body, cb)
  if anchor.subject_type ~= "FILE" then
    local ok, why = diff.valid(R.idx, anchor)
    if not ok then return cb(why) end
  end
  ensure_pending(R, function(e, rid)
    if e then return cb(e) end
    local vars = { review = rid, path = anchor.path, body = body }
    if anchor.subject_type == "FILE" then
      vars.subjectType = "FILE"
    else
      vars.line, vars.side = anchor.line, anchor.side
      if anchor.start_line and anchor.start_line ~= anchor.line then
        vars.startLine, vars.startSide = anchor.start_line, anchor.start_side or anchor.side
      end
    end
    gh.graphql(queries.add_thread, vars, function(e2, d)
      if e2 then return cb(e2) end
      local t = vim.tbl_get(d or {}, "addPullRequestReviewThread", "thread")
      if not t then return cb("GitHub didn't return the new thread") end
      table.insert(R.threads, norm_thread(t))
      render(R)
      cb(nil)
    end)
  end)
end

local function cursor_row(R) return vim.api.nvim_win_get_cursor(R.win)[1] end

-- threads (not drafts) on the cursor row; several → pick one
local function with_thread(R, fn)
  local list = vim.tbl_filter(function(e) return e.thread end, R.at[cursor_row(R)] or {})
  if #list == 0 then return vim.notify("upstream: no thread on this line (]t jumps to one)", vim.log.levels.WARN) end
  if #list == 1 then return fn(list[1].thread) end
  local items = {}
  for _, e in ipairs(list) do
    local c = e.thread.comments[1] or {}
    items[#items + 1] = { label = (c.author or "?") .. ": " .. ((c.body or ""):gsub("%s+", " ")):sub(1, 60), value = e.thread }
  end
  require("upstream.ui.pick").open({ title = "Thread", items = items }, function(ch) if ch then fn(ch.value) end end)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------

function M.comment(R, visual)
  local row = cursor_row(R)
  local srow = row
  if visual then
    srow = vim.fn.line("v")
    vim.cmd("normal! \27")
    if srow > row then srow, row = row, srow end
  end
  local info_e, info_s = R.rows[row], R.rows[srow]
  local anchor
  if info_e and info_e.kind == "file" and srow == row then
    anchor = { path = info_e.path, subject_type = "FILE" }
  elseif info_e and info_e.kind == "line" and info_s and info_s.kind == "line" then
    anchor = { path = info_e.path, side = info_e.side, line = info_e.line }
    if srow ~= row then
      if info_s.path ~= info_e.path or info_s.hunk ~= info_e.hunk then
        return vim.notify("upstream: a comment range must stay within one hunk", vim.log.levels.WARN)
      end
      anchor.start_line, anchor.start_side = info_s.line, info_s.side
    end
  else
    return vim.notify("upstream: put the cursor on a diff line (or a file header for a file comment)",
      vim.log.levels.WARN)
  end
  local where = anchor.subject_type == "FILE" and anchor.path
    or ("%s:%s%d"):format(anchor.path, anchor.start_line and (anchor.start_line .. "–") or "", anchor.line)
  compose.open(R.repo, {
    key = ("pr-%d-thread-%s-%s-%s"):format(R.number, anchor.path, anchor.side or "F", anchor.line or 0),
    title = "comment on " .. where,
    split = true,
    submit = function(_, body, done)
      if body == "" then return done("the comment is empty") end
      M.add_thread(R, anchor, body, done)
    end,
    on_done = function()
      info("added to your pending review (S submits)")
      if vim.api.nvim_win_is_valid(R.win) then vim.api.nvim_set_current_win(R.win) end
    end,
  })
end

function M.reply(R)
  with_thread(R, function(t)
    compose.open(R.repo, {
      key = ("pr-%d-reply-%s"):format(R.number, t.id),
      title = "reply to " .. ((t.comments[1] or {}).author or "thread"),
      split = true,
      submit = function(_, body, done)
        if body == "" then return done("the reply is empty") end
        gh.graphql(queries.reply_thread, { thread = t.id, body = body, review = R.pending and R.pending.id },
          function(e, d)
            if e then return done(e) end
            local c = vim.tbl_get(d or {}, "addPullRequestReviewThreadReply", "comment")
            if c then table.insert(t.comments, norm_comment(c)) end
            render(R)
            done(nil)
          end)
      end,
      on_done = function()
        if vim.api.nvim_win_is_valid(R.win) then vim.api.nvim_set_current_win(R.win) end
      end,
    })
  end)
end

function M.resolve(R)
  with_thread(R, function(t)
    local q = t.resolved and queries.unresolve_thread or queries.resolve_thread
    gh.graphql(q, { id = t.id }, function(e)
      if e then return err_notify(e) end
      t.resolved = not t.resolved
      render(R)
      data.touch(R.repo, "pr-" .. R.number)
    end)
  end)
end

-- the whole thread(s) on the cursor row in a markdown float
function M.show(R, list)
  list = list or vim.tbl_map(function(e) return e.thread end,
    vim.tbl_filter(function(e) return e.thread end, R.at[cursor_row(R)] or {}))
  if #list == 0 then return vim.notify("upstream: no thread on this line", vim.log.levels.WARN) end
  local out = {}
  for ti, t in ipairs(list) do
    if ti > 1 then vim.list_extend(out, { "", "---", "" }) end
    local where = t.line and ("%s:%d"):format(t.path, t.line) or (t.path .. (t.original_line and (" (was line " .. t.original_line .. ")") or ""))
    out[#out + 1] = ("**%s**%s%s"):format(where, t.resolved and " · resolved" or "", t.outdated and " · outdated" or "")
    for _, c in ipairs(t.comments) do
      out[#out + 1] = ""
      out[#out + 1] = ("### %s · %s%s"):format(c.author, ago(c.at), c.pending and " · pending" or "")
      vim.list_extend(out, vim.split(c.body:gsub("\r", ""), "\n", { plain = true }))
    end
  end
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, out)
  vim.bo[b].modifiable = false
  vim.bo[b].filetype = "markdown"
  local w = math.min(100, vim.o.columns - 8)
  local h = math.min(#out + 2, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", row = math.floor((vim.o.lines - h) / 2), col = math.floor((vim.o.columns - w) / 2),
    width = w, height = h, style = "minimal", border = "rounded", title = " thread ", title_pos = "center",
  })
  vim.wo[win].wrap, vim.wo[win].linebreak, vim.wo[win].conceallevel = true, true, 2
  vim.wo[win].winhighlight = hl.winhl()
  for _, k in ipairs({ "q", "<Esc>", "K" }) do
    vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = b, nowait = true })
  end
end

function M.jump(R, step)
  local row = cursor_row(R)
  local target
  if step > 0 then
    for _, r in ipairs(R.thread_rows) do
      if r > row then target = r break end
    end
  else
    for i = #R.thread_rows, 1, -1 do
      if R.thread_rows[i] < row then target = R.thread_rows[i] break end
    end
  end
  if target then vim.api.nvim_win_set_cursor(R.win, { target, 0 }) end
end

function M.jump_file(R, step)
  local row = cursor_row(R)
  local list = {}
  for _, r in pairs(R.file_rows) do list[#list + 1] = r end
  table.sort(list)
  local target
  if step > 0 then
    for _, r in ipairs(list) do if r > row then target = r break end end
  else
    for i = #list, 1, -1 do if list[i] < row then target = list[i] break end end
  end
  if target then
    vim.api.nvim_win_set_cursor(R.win, { target, 0 })
    vim.cmd("normal! zt")
  end
end

-- every thread, outdated ones included
function M.thread_list(R)
  local items = {}
  for _, t in ipairs(R.threads) do
    local c = t.comments[1] or {}
    local tags = (t.resolved and "✓ " or "") .. (t.outdated and "outdated " or "")
    local row = t.file_level and R.file_rows[t.path] or (t.line and not t.outdated and R.anchors[akey(t.path, t.side, t.line)])
    items[#items + 1] = {
      label = ("%s%s:%s"):format(tags, t.path, t.line or t.original_line or "file"),
      desc = (c.author or "?") .. ": " .. ((c.body or ""):gsub("%s+", " ")):sub(1, 50),
      value = { t = t, row = row },
    }
  end
  if #items == 0 then return info("no review threads yet") end
  require("upstream.ui.pick").open({ title = "Threads", items = items }, function(ch)
    if not ch then return end
    if ch.value.row then
      vim.api.nvim_win_set_cursor(R.win, { ch.value.row, 0 })
    else
      M.show(R, { ch.value.t })
    end
  end)
end

local EVENTS = { "COMMENT", "APPROVE", "REQUEST_CHANGES" }

function M.submit(R)
  local c = vim.fn.confirm(("Submit your review of #%d as…"):format(R.number),
    "&Comment\n&Approve\n&Request changes\n&Cancel", 1, "Question")
  local event = EVENTS[c]
  if not event then return end
  compose.open(R.repo, {
    key = ("pr-%d-review"):format(R.number),
    title = event:lower():gsub("_", " ") .. " review of #" .. R.number,
    split = true,
    submit = function(_, body, done)
      if body == "" and event == "REQUEST_CHANGES" then return done("requesting changes needs a comment") end
      if body == "" and event == "COMMENT" and not R.pending then return done("the review is empty") end
      local q, vars, path
      if R.pending then
        q, vars, path = queries.submit_review, { review = R.pending.id, event = event, body = body },
          { "submitPullRequestReview", "pullRequestReview" }
      else
        q, vars, path = queries.review_now, { pr = R.pr.id, event = event, body = body },
          { "addPullRequestReview", "pullRequestReview" }
      end
      gh.graphql(q, vars, function(e, d)
        if e then return done(e) end
        if not vim.tbl_get(d or {}, unpack(path)) then return done("GitHub didn't confirm the review") end
        done(nil)
      end)
    end,
    on_done = function()
      info(("review submitted (%s)"):format(event:lower():gsub("_", " ")))
      R.pending = nil
      M.reload(R)
      data.detail(R.repo, "pr", R.number, function() end, true)
    end,
  })
end

function M.discard(R)
  if not R.pending then return info("no pending review") end
  if vim.fn.confirm("Discard your pending review and all its comments?", "&Discard\n&Cancel", 2, "Warning") ~= 1 then
    return
  end
  gh.graphql(queries.discard_review, { id = R.pending.id }, function(e)
    if e then return err_notify(e) end
    R.pending = nil
    info("pending review discarded")
    M.reload(R)
  end)
end

-- ---------------------------------------------------------------------------
-- AI review assist
-- ---------------------------------------------------------------------------

-- findings → drafts. Each anchor is validated against the hunks: a bad line
-- in a file that is in the diff becomes a file-level comment (with the line
-- named in the body); a file that isn't in the diff is dropped.
function M.to_drafts(R, findings)
  local drafts, file_level, dropped = {}, 0, 0
  for _, f in ipairs(findings) do
    local anchor = { path = f.path, side = f.side, line = f.line }
    if f.start_line and f.line and f.start_line < f.line then
      anchor.start_line, anchor.start_side = f.start_line, f.side
    end
    local ok = f.line and diff.valid(R.idx, anchor)
    if not ok and anchor.start_line then
      -- the range is bad; the end line alone may still be fine
      anchor.start_line, anchor.start_side = nil, nil
      ok = diff.valid(R.idx, anchor)
    end
    local body = f.body
    if not ok then
      if R.idx[f.path] then
        anchor = { path = f.path, subject_type = "FILE" }
        if f.line then body = ("_(line %d)_ %s"):format(f.line, body) end
        file_level = file_level + 1
      else
        anchor = nil
        dropped = dropped + 1
      end
    end
    if anchor then drafts[#drafts + 1] = { anchor = anchor, body = body, severity = f.severity } end
  end
  return drafts, file_level, dropped
end

function M.assist(R)
  if R.assisting then return info("the AI review is still running") end
  R.assisting = true
  ai.review({
    repo = R.repo, number = R.number, title = R.pr.title, body = R.pr.body,
    closes = vim.tbl_get(R.pr, "closingIssuesReferences", "nodes"),
    annotated = diff.annotated(R.files),
  }, function(e, findings)
    R.assisting = false
    if e then return err_notify(e) end
    if not vim.api.nvim_buf_is_valid(R.buf) then return end
    local drafts, file_level, dropped = M.to_drafts(R, findings)
    vim.list_extend(R.drafts, drafts)
    render(R)
    local msg = ("%d AI draft%s"):format(#drafts, #drafts == 1 and "" or "s")
    if file_level > 0 then msg = msg .. (", %d moved to file level"):format(file_level) end
    if dropped > 0 then msg = msg .. (", %d dropped (file not in the diff)"):format(dropped) end
    info(msg)
    if #R.drafts > 0 then require("upstream.review.drafts").open(R) end
  end)
end

-- ---------------------------------------------------------------------------
-- lifecycle
-- ---------------------------------------------------------------------------

function M.reload(R)
  fetch(R, function(e)
    if e then return err_notify(e) end
    render(R)
  end)
end

function M.render(R) render(R) end

local function help()
  local rows = {
    { "c", "comment on the line (visual: a range; file header: the file)" },
    { "r / x", "reply to / resolve (or unresolve) the thread on the line" },
    { "K", "read the thread(s) on the line" },
    { "]t [t", "next / previous thread" },
    { "]f [f", "next / previous file" },
    { "T", "all threads (outdated ones included)" },
    { "S / D", "submit the review / discard the pending review" },
    { "A / gd", "AI review assist / its drafts list" },
    { "gf", "open the file at this line (local checkout)" },
    { "R / gx", "reload / open the PR's files in the browser" },
    { "q", "close the review" },
  }
  local lines = { "" }
  for _, r in ipairs(rows) do lines[#lines + 1] = ("  %-8s %s"):format(r[1], r[2]) end
  lines[#lines + 1] = ""
  local b = vim.api.nvim_create_buf(false, true)
  vim.bo[b].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  for i = 1, #rows do vim.api.nvim_buf_set_extmark(b, ns, i, 2, { end_col = 10, hl_group = "UpstreamAccent" }) end
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l) + 2) end
  local win = vim.api.nvim_open_win(b, true, {
    relative = "editor", row = math.floor((vim.o.lines - #lines) / 2), col = math.floor((vim.o.columns - w) / 2),
    width = w, height = #lines, style = "minimal", border = "rounded", title = " review keys ", title_pos = "center",
  })
  vim.wo[win].winhighlight = hl.winhl()
  for _, k in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", k, function() pcall(vim.api.nvim_win_close, win, true) end, { buffer = b, nowait = true })
  end
end

local function keymaps(R)
  local function map(mode, lhs, fn)
    vim.keymap.set(mode, lhs, fn, { buffer = R.buf, nowait = true, silent = true })
  end
  map("n", "c", function() M.comment(R, false) end)
  map("x", "c", function() M.comment(R, true) end)
  map("n", "r", function() M.reply(R) end)
  map("n", "x", function() M.resolve(R) end)
  map("n", "K", function() M.show(R) end)
  map("n", "]t", function() M.jump(R, 1) end)
  map("n", "[t", function() M.jump(R, -1) end)
  map("n", "]f", function() M.jump_file(R, 1) end)
  map("n", "[f", function() M.jump_file(R, -1) end)
  map("n", "T", function() M.thread_list(R) end)
  map("n", "S", function() M.submit(R) end)
  map("n", "D", function() M.discard(R) end)
  map("n", "A", function() M.assist(R) end)
  map("n", "gd", function() require("upstream.review.drafts").open(R) end)
  map("n", "R", function() M.reload(R) end)
  map("n", "gx", function() if R.pr and R.pr.url then vim.ui.open(R.pr.url .. "/files") end end)
  map("n", "gf", function()
    local i = R.rows[cursor_row(R)]
    if not i or not i.path then return end
    vim.cmd(("vsplit +%d %s"):format(i.new or 1, vim.fn.fnameescape(i.path)))
  end)
  map("n", "?", help)
  map("n", "q", function()
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose()
    else
      pcall(vim.api.nvim_buf_delete, R.buf, { force = true })
    end
  end)
end

-- open(repo, number, { assist = true }): the review tab for PR #number
function M.open(repo, number, opts)
  opts = opts or {}
  local ui = require("upstream.ui")
  if ui.is_open() then ui.close() end
  local name = ("upstream://%s/pr/%d/review"):format(repo.full, number)
  for b, R in pairs(reviews) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      local win = vim.fn.win_findbuf(b)[1]
      if win then
        vim.api.nvim_set_current_win(win)
      else
        vim.cmd.tabnew()
        vim.api.nvim_win_set_buf(0, b)
        R.win = vim.api.nvim_get_current_win()
      end
      if opts.assist then M.assist(R) end
      return
    end
  end
  hl.setup()
  vim.cmd.tabnew()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "upstream_review"
  local win = vim.api.nvim_get_current_win()
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].foldenable = false
  vim.wo[win].cursorline = true
  vim.wo[win].list = false
  local R = { repo = repo, number = number, buf = buf, win = win, files = {}, threads = {}, drafts = {},
              rows = {}, at = {}, thread_rows = {}, anchors = {}, file_rows = {}, unanchored = {}, idx = {} }
  reviews[buf] = R
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { ("PR #%d · loading the diff and threads…"):format(number) })
  vim.bo[buf].modifiable = false
  keymaps(R)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = function() reviews[buf] = nil end })
  -- thread bodies are wrapped to the window width
  local group = vim.api.nvim_create_augroup("upstream_review_" .. buf, { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if not vim.api.nvim_buf_is_valid(buf) then return true end
      if R.pr then render(R) end
    end,
  })
  fetch(R, function(e)
    if e then
      if vim.api.nvim_buf_is_valid(buf) then
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "PR #" .. number .. ": " .. e })
        vim.bo[buf].modifiable = false
      end
      return err_notify(e)
    end
    render(R)
    pcall(vim.api.nvim_win_set_cursor, R.win, { math.min(5, vim.api.nvim_buf_line_count(buf)), 0 })
    if opts.assist then M.assist(R) end
  end)
end

return M
