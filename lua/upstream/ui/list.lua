-- List pane rendering: items → lines + highlight spans. One item per line so
-- j/k/G work natively; the final "load more" row triggers the next page.

local M = {}

-- glyph, highlight for an item's state
local function state_glyph(it)
  if it.kind == "run" then
    if it.status ~= "completed" then return "", "UpstreamPending" end
    if it.conclusion == "success" then return "", "UpstreamOpen" end
    if it.conclusion == "failure" or it.conclusion == "timed_out" then return "", "UpstreamClosed" end
    return "", "UpstreamMuted"
  end
  if it.kind == "pr" then
    if it.state == "MERGED" then return "", "UpstreamMerged" end
    if it.state == "CLOSED" then return "", "UpstreamClosed" end
    if it.draft then return "", "UpstreamDraft" end
    return "", "UpstreamOpen"
  end
  if it.state == "CLOSED" then return "", "UpstreamMerged" end
  return "", "UpstreamOpen"
end

M.CHECKS = {
  SUCCESS = { "✓", "UpstreamOpen" },
  FAILURE = { "✗", "UpstreamClosed" },
  ERROR = { "✗", "UpstreamClosed" },
  PENDING = { "●", "UpstreamPending" },
  EXPECTED = { "●", "UpstreamPending" },
}

-- Does `it` match the filter? Case-insensitive, all words must match one of
-- title / #number / author / labels / branch.
function M.matches(it, filter)
  if not filter or filter == "" then return true end
  local hay = { (it.title or ""):lower(), "#" .. tostring(it.number), (it.author or ""):lower(),
                (it.head or ""):lower(), (it.workflow or ""):lower() }
  for _, l in ipairs(it.labels or {}) do hay[#hay + 1] = l.name:lower() end
  local s = table.concat(hay, " ")
  for word in filter:lower():gmatch("%S+") do
    if not s:find(word, 1, true) then return false end
  end
  return true
end

-- render(view) → lines, spans, rows. spans = { {row, col_start,
-- col_end, hl} } (0-based, byte columns); rows[i] = item | "more" | nil.
function M.render(view)
  local lines, spans, rows = {}, {}, {}
  local function add(chunks, row_item)
    local line, col = "", 0
    local r = #lines
    for _, c in ipairs(chunks) do
      local text, hl = c[1], c[2]
      if hl then spans[#spans + 1] = { r, col, col + #text, hl } end
      line = line .. text
      col = col + #text
    end
    lines[#lines + 1] = line
    rows[#lines] = row_item
  end

  if view.error and #view.items == 0 then
    add({ { " " .. view.error, "UpstreamClosed" } })
    return lines, spans, rows
  end
  if not view.loaded and #view.items == 0 then
    add({ { " loading…", "UpstreamMuted" } })
    return lines, spans, rows
  end

  for _, it in ipairs(view.items) do
    if M.matches(it, view.filter) then
      local glyph, ghl = state_glyph(it)
      local chunks = { { " " .. glyph .. " ", ghl } }
      if it.kind == "run" then
        chunks[#chunks + 1] = { it.workflow or "?", "UpstreamAccent" }
        chunks[#chunks + 1] = { " " .. (it.title or "") }
        if it.head then chunks[#chunks + 1] = { "  " .. it.head, "UpstreamMuted" } end
      else
        chunks[#chunks + 1] = { "#" .. it.number .. " ", "UpstreamNumber" }
        chunks[#chunks + 1] = { it.title or "" }
        local ck = it.checks and M.CHECKS[it.checks]
        if ck then chunks[#chunks + 1] = { " " .. ck[1], ck[2] } end
        if (it.comments or 0) > 0 then chunks[#chunks + 1] = { "  " .. it.comments, "UpstreamMuted" } end
        for _, l in ipairs(it.labels or {}) do
          chunks[#chunks + 1] = { "  " .. l.name, "UpstreamLabel" }
        end
      end
      add(chunks, it)
    end
  end

  if #lines == 0 then
    add({ { view.filter ~= "" and " no matches" or " nothing here", "UpstreamMuted" } })
  end
  if view.has_next then
    add({ { view.loading_more and "   loading more…" or "   load more…", "UpstreamMuted" } }, "more")
  end
  return lines, spans, rows
end

return M
