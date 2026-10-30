-- Compose buffers: comments, edits, new issues/PRs, review bodies. A
-- `buftype=acwrite` markdown buffer where `:w` submits (BufWriteCmd). An
-- optional header block holds the metadata, then a `---` line, then the body:
--
--   title: feat(github): browse issues
--   base: main   head: feat/x   draft: false
--   labels: enhancement, area:ui
--
--   ---
--   body…
--
-- Pairs on one line are separated by 2+ spaces; `title:` always takes the
-- rest of its line. The blank line before `---` keeps markdown from reading
-- the last header line as a setext heading.
--
-- Every :w first saves the text under stdpath("cache")/upstream/drafts/, so a
-- failed submit (or `:wq` on one) never loses it; reopening the same compose
-- buffer restores the draft. A successful submit deletes it.

local config = require("upstream.config")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream_compose")
local drafts = vim.fn.stdpath("cache") .. "/upstream/drafts"

local function draft_path(repo, key)
  return ("%s/%s/%s/%s.md"):format(drafts, repo.owner, repo.name, key:gsub("[^%w%-_]", "_"))
end

local function read_file(p)
  local f = io.open(p, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(p, s)
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  local f = io.open(p, "w")
  if not f then return end
  f:write(s)
  f:close()
end

-- header spec { { {"title", "x"} }, { {"base", "main"}, {"draft", "false"} } } → lines
local function header_lines(header)
  local out = {}
  for _, row in ipairs(header) do
    local parts = {}
    for _, kv in ipairs(row) do parts[#parts + 1] = kv[1] .. ": " .. (kv[2] or "") end
    out[#out + 1] = table.concat(parts, "   ")
  end
  out[#out + 1] = ""
  out[#out + 1] = "---"
  return out
end

-- lines → fields, body | nil, err. `keys` = the allowed header keys.
function M.parse(lines, keys)
  if not keys then return {}, vim.trim(table.concat(lines, "\n")) end
  local sep
  for i, l in ipairs(lines) do
    if l == "---" then
      sep = i
      break
    end
  end
  if not sep then return nil, "the header must end with a `---` line" end
  local allowed, fields = {}, {}
  for _, k in ipairs(keys) do allowed[k] = true end
  for i = 1, sep - 1 do
    local line = lines[i]
    if vim.trim(line) ~= "" then
      local tk, tv = line:match("^%s*(title):%s*(.-)%s*$")
      local segs = tk and { { tk, tv } } or {}
      if not tk then
        for seg in (line .. "  "):gmatch("(.-)%s%s+") do
          if seg ~= "" then
            local k, v = seg:match("^%s*([%a_]+):%s*(.-)%s*$")
            if not k then return nil, ("line %d: expected `key: value`, got %q"):format(i, seg) end
            segs[#segs + 1] = { k, v }
          end
        end
      end
      for _, kv in ipairs(segs) do
        if not allowed[kv[1]] then
          return nil, ("line %d: unknown field `%s` (expected: %s)"):format(i, kv[1], table.concat(keys, ", "))
        end
        fields[kv[1]] = kv[2]
      end
    end
  end
  return fields, vim.trim(table.concat(vim.list_slice(lines, sep + 1), "\n"))
end

-- "a, b ,c" → { "a", "b", "c" }
function M.list(s)
  local out = {}
  for x in (s or ""):gmatch("[^,]+") do
    x = vim.trim(x):gsub("^@", "")
    if x ~= "" then out[#out + 1] = x end
  end
  return out
end

function M.bool(s) return s == "true" or s == "yes" or s == "1" end

-- After a submit: close the window it got (split/tab), or put the previous
-- buffer back in it (current), then wipe it.
local function close_buf(buf, own_win)
  if not vim.api.nvim_buf_is_valid(buf) then return end
  for _, win in ipairs(vim.fn.win_findbuf(buf)) do
    if own_win and pcall(vim.api.nvim_win_close, win, true) then
      -- closed (fails for the last window of the last tab)
    else
      local alt = vim.fn.bufnr("#")
      if alt > 0 and alt ~= buf and vim.api.nvim_buf_is_valid(alt) and vim.bo[alt].buflisted then
        vim.api.nvim_win_set_buf(win, alt)
      else
        vim.api.nvim_win_call(win, function() vim.cmd.enew() end)
      end
    end
  end
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- open(repo, spec):
--   key      unique per target, e.g. "issue-12-comment" (buffer name + draft file)
--   title    shown in the buffer name
--   header   header spec (nil = body only); keys = the allowed header keys
--   body     initial body
--   split    open in a split below instead of the current window
--   submit   function(fields, body, done) — call done(err) or done(nil)
--   on_done  called after a successful submit (buffer already closed)
function M.open(repo, spec)
  local name = ("upstream://%s/%s"):format(repo.full, spec.key)
  local existing = vim.fn.bufnr(name)
  if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
    local win = vim.fn.win_findbuf(existing)[1]
    if win then
      vim.api.nvim_set_current_win(win)
    else
      vim.api.nvim_set_current_buf(existing)
    end
    return existing
  end

  local layout = spec.split and "split" or config.options.compose
  if layout == "split" then
    vim.cmd("botright " .. math.max(12, math.floor(vim.o.lines * 0.35)) .. "new")
  elseif layout == "vsplit" then
    vim.cmd("botright vnew")
  elseif layout == "tab" then
    vim.cmd("tabnew")
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_buf_set_name(buf, name)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.b[buf].upstream_compose = true

  local keys = spec.header and spec.keys or nil
  local dp = draft_path(repo, spec.key)
  local saved = read_file(dp)
  local lines
  if saved then
    lines = vim.split(saved, "\n", { plain = true })
    vim.notify("upstream: restored your unsent draft", vim.log.levels.INFO)
  else
    lines = spec.header and header_lines(spec.header) or {}
    vim.list_extend(lines, vim.split((spec.body or ""):gsub("\r", ""), "\n", { plain = true }))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = saved ~= nil

  -- hint on the first line (or the separator)
  local hint_row = 0
  for i, l in ipairs(lines) do
    if keys and l == "---" then hint_row = i - 1 end
  end
  vim.api.nvim_buf_set_extmark(buf, ns, hint_row, 0, {
    virt_text = { { "  " .. (spec.title or "compose") .. " · :w submits · :q asks before discarding", "UpstreamMuted" } },
    virt_text_pos = "eol",
  })

  -- cursor: first empty header value, else the body
  local row = #lines
  if keys then
    for i, l in ipairs(lines) do
      if l:match("^title:%s*$") then row = i break end
      if l == "---" then row = math.min(i + 1, #lines) break end
    end
  else
    row = 1
  end
  pcall(vim.api.nvim_win_set_cursor, 0, { row, #(lines[row] or "") })

  local busy = false
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if busy then return vim.notify("upstream: still submitting…", vim.log.levels.WARN) end
      local cur = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      write_file(dp, table.concat(cur, "\n"))
      local fields, body = M.parse(cur, keys)
      if not fields then return vim.notify("upstream: " .. body, vim.log.levels.ERROR) end
      busy = true
      -- the write "succeeds" now so `:wq` can go on; a failed submit sets
      -- 'modified' back and the draft file still has the text
      vim.bo[buf].modified = false
      local tick = vim.api.nvim_buf_get_changedtick(buf)
      vim.notify("upstream: submitting " .. (spec.title or "") .. "…", vim.log.levels.INFO)
      spec.submit(fields, body, function(err)
        busy = false
        if err then
          if vim.api.nvim_buf_is_valid(buf) then vim.bo[buf].modified = true end
          return vim.notify(("upstream: %s\nDraft kept in %s"):format(err, vim.fn.fnamemodify(dp, ":~")),
            vim.log.levels.ERROR)
        end
        os.remove(dp)
        if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_changedtick(buf) == tick then
          close_buf(buf, layout ~= "current")
        end
        if spec.on_done then spec.on_done() end
      end)
    end,
  })
  return buf
end

return M
