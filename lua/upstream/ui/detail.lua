-- Detail pane: an item → markdown lines. The buffer is filetype=markdown so
-- render-markdown (or plain treesitter) draws the body; the metadata is
-- written as markdown too, so no extmarks are needed here.

local M = {}

-- "2024-05-01T12:00:00Z" → seconds since the epoch (UTC)
local function parse_iso(s)
  local y, mo, d, h, mi, se = (s or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
  if not y then return nil end
  local t = os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = se, isdst = false })
  -- os.time read the fields as local time; shift back to UTC
  local now = os.time()
  return t + (now - os.time(os.date("!*t", now) --[[@as osdateparam]]))
end

function M.ago(iso)
  local t = parse_iso(iso)
  if not t then return "" end
  local s = math.max(0, os.time() - t)
  if s < 60 then return "just now" end
  if s < 3600 then return math.floor(s / 60) .. "m ago" end
  if s < 86400 then return math.floor(s / 3600) .. "h ago" end
  if s < 86400 * 30 then return math.floor(s / 86400) .. "d ago" end
  if s < 86400 * 365 then return math.floor(s / (86400 * 30)) .. "mo ago" end
  return math.floor(s / (86400 * 365)) .. "y ago"
end

local function thousands(n)
  local s = tostring(n or 0)
  while true do
    local r, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
    s = r
    if k == 0 then return s end
  end
end

local function body_lines(out, body)
  body = (body or ""):gsub("\r", "")
  if vim.trim(body) == "" then
    out[#out + 1] = "_No description provided._"
    return
  end
  vim.list_extend(out, vim.split(body, "\n", { plain = true }))
end

local CHECK_TEXT = {
  SUCCESS = "✓ checks", FAILURE = "✗ checks failing", ERROR = "✗ checks errored",
  PENDING = "● checks running", EXPECTED = "● checks expected",
}

local REVIEW_TEXT = {
  APPROVED = "approved", CHANGES_REQUESTED = "requested changes",
  COMMENTED = "reviewed", DISMISSED = "review dismissed", PENDING = "pending review",
}

local function state_text(it)
  if it.kind == "pr" and it.draft and it.state == "OPEN" then return "Draft" end
  return ({ OPEN = "Open", CLOSED = "Closed", MERGED = "Merged" })[it.state] or it.state or ""
end

local RUN_GLYPH = { success = "✓", failure = "✗", timed_out = "✗", cancelled = "⊘", skipped = "–" }

local function run_glyph(x)
  if x.status and x.status ~= "completed" then return "●" end
  return RUN_GLYPH[x.conclusion or ""] or "·"
end

local function run_lines(it)
  local out = {
    "# " .. (it.workflow or "workflow"),
    "",
    "**" .. (it.title or "") .. "**",
    "",
    ("`%s` · %s · %s"):format(it.head or "?", it.event or "?", M.ago(it.created)),
    "",
    "Status: **" .. (it.status or "?") .. "**" .. (it.conclusion and it.conclusion ~= ""
      and (" · conclusion: **" .. it.conclusion .. "**") or ""),
  }
  if it.jobs then
    out[#out + 1] = ""
    out[#out + 1] = "## Jobs"
    for _, j in ipairs(it.jobs) do
      out[#out + 1] = ""
      out[#out + 1] = ("- %s **%s**"):format(run_glyph(j), j.name or "job")
      for _, st in ipairs(j.steps or {}) do
        -- skipped steps are noise in a long workflow
        if st.conclusion ~= "skipped" then
          out[#out + 1] = ("  - %s %s"):format(run_glyph(st), st.name or "")
        end
      end
    end
  else
    out[#out + 1] = ""
    out[#out + 1] = "_loading jobs…_"
  end
  out[#out + 1] = ""
  out[#out + 1] = "_L log · R re-run · x cancel · gx open in the browser_"
  return out
end

-- lines(it) → string[]
function M.lines(it)
  if it.kind == "run" then return run_lines(it) end
  local out = {}
  out[#out + 1] = ("# #%d %s"):format(it.number, it.title or "")
  out[#out + 1] = ""

  local who = "**" .. (it.author or "ghost") .. "**"
  if it.kind == "pr" then
    local verb = it.state == "MERGED" and "merged" or "wants to merge"
    out[#out + 1] = ("%s · %s %s `%s` → `%s`"):format(state_text(it), who, verb, it.head or "?", it.base or "?")
    local meta = {}
    if it.checks and CHECK_TEXT[it.checks] then meta[#meta + 1] = CHECK_TEXT[it.checks] end
    if (it.approvals or 0) > 0 then meta[#meta + 1] = it.approvals .. (it.approvals == 1 and " approval" or " approvals") end
    if it.review == "CHANGES_REQUESTED" then meta[#meta + 1] = "changes requested" end
    if it.additions then
      meta[#meta + 1] = ("+%s −%s"):format(thousands(it.additions), thousands(it.deletions))
      meta[#meta + 1] = it.files .. (it.files == 1 and " file" or " files")
    end
    if it.mergeable == "CONFLICTING" then meta[#meta + 1] = "⚠ conflicts" end
    if #meta > 0 then out[#out + 1] = table.concat(meta, " · ") end
  else
    out[#out + 1] = ("%s · %s opened %s"):format(state_text(it), who, M.ago(it.created))
  end

  local facts = {}
  if it.labels and #it.labels > 0 then
    facts[#facts + 1] = "- Labels: " .. table.concat(vim.tbl_map(function(l) return "`" .. l.name .. "`" end, it.labels), " ")
  end
  if it.assignees and #it.assignees > 0 then
    facts[#facts + 1] = "- Assignees: " .. table.concat(vim.tbl_map(function(a) return "@" .. a end, it.assignees), ", ")
  end
  if it.reviewers and #it.reviewers > 0 then
    facts[#facts + 1] = "- Reviewers: " .. table.concat(vim.tbl_map(function(a)
      return "@" .. (type(a) == "table" and a.name or a)
    end, it.reviewers), ", ")
  end
  if it.milestone then facts[#facts + 1] = "- Milestone: " .. it.milestone end
  if it.closes and #it.closes > 0 then
    facts[#facts + 1] = "- Closes: " .. table.concat(vim.tbl_map(function(i) return "#" .. i.number end, it.closes), ", ")
  end
  if #facts > 0 then
    out[#out + 1] = ""
    vim.list_extend(out, facts)
  end

  out[#out + 1] = ""
  out[#out + 1] = "---"
  out[#out + 1] = ""
  if it.body == nil then
    out[#out + 1] = "_loading…_"
    return out
  end
  body_lines(out, it.body)

  local tl = it.timeline or {}
  local ncomments = 0
  for _, t in ipairs(tl) do
    if t.type == "comment" then ncomments = ncomments + 1 end
  end
  out[#out + 1] = ""
  out[#out + 1] = ("## ── %d comment%s ──"):format(ncomments, ncomments == 1 and "" or "s")
  if (it.timeline_total or 0) > #tl then
    out[#out + 1] = ("_showing the latest %d of %d events_"):format(#tl, it.timeline_total)
  end
  for _, t in ipairs(tl) do
    out[#out + 1] = ""
    if t.type == "comment" then
      out[#out + 1] = ("### %s · %s"):format(t.author, M.ago(t.at))
      out[#out + 1] = ""
      body_lines(out, t.body)
    elseif t.type == "review" then
      out[#out + 1] = ("### %s %s · %s"):format(t.author, REVIEW_TEXT[t.state] or "reviewed", M.ago(t.at))
      if vim.trim(t.body or "") ~= "" then
        out[#out + 1] = ""
        body_lines(out, t.body)
      end
    elseif t.type == "commit" then
      out[#out + 1] = ("- `%s` %s · _%s_"):format(t.oid or "", t.body or "", t.author)
    elseif t.type == "reference" then
      out[#out + 1] = ("_%s mentioned this in %s #%d %s · %s_"):format(
        t.author, t.ref.pr and "PR" or "issue", t.ref.number, t.ref.title or "", M.ago(t.at))
    else
      out[#out + 1] = ("_%s %s this · %s_"):format(t.author, t.type, M.ago(t.at))
    end
  end
  return out
end

return M
