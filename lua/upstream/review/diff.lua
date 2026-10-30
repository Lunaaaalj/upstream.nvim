-- Unified diff (as printed by `gh pr diff`) → files and hunks, plus the
-- anchor model GitHub uses for review comments.
--
-- A comment is anchored by path + side + line: RIGHT = a line of the new file
-- (an added `+` or context line), LEFT = a line of the old file (a removed `-`
-- line). GitHub only accepts lines inside a hunk, and a multi-line range must
-- stay within one hunk, so `valid()` enforces both before anything is sent.

local M = {}

-- parse(text) → { { path, old_path, status, binary, additions, deletions,
--   hunks = { { header, old_start, new_start, lines = { {kind, text, old, new} } } } } }
function M.parse(text)
  local files, f, h = {}, nil, nil
  local old_ln, new_ln = 0, 0
  for line in ((text or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    local a, b = line:match("^diff %-%-git a/(.-) b/(.*)$")
    if a then
      f = { path = b, old_path = a, status = "modified", hunks = {}, additions = 0, deletions = 0 }
      files[#files + 1] = f
      h = nil
    elseif f and not h then
      if line:match("^new file mode") then
        f.status = "added"
      elseif line:match("^deleted file mode") then
        f.status = "deleted"
      elseif line:match("^rename from ") then
        f.status = "renamed"
      elseif line:match("^Binary files ") then
        f.binary = true
      elseif line:match("^%-%-%- ") then
        local p = line:match("^%-%-%- a/(.*)$")
        if p then f.old_path = p end
      elseif line:match("^%+%+%+ ") then
        local p = line:match("^%+%+%+ b/(.*)$")
        if p then f.path = p end
      end
    end
    if f then
      local os_, ns_ = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      if os_ then
        h = { header = line, old_start = tonumber(os_), new_start = tonumber(ns_), lines = {} }
        f.hunks[#f.hunks + 1] = h
        old_ln, new_ln = h.old_start, h.new_start
      elseif h then
        local c = line:sub(1, 1)
        if c == "+" then
          h.lines[#h.lines + 1] = { kind = "+", text = line:sub(2), new = new_ln }
          new_ln = new_ln + 1
          f.additions = f.additions + 1
        elseif c == "-" then
          h.lines[#h.lines + 1] = { kind = "-", text = line:sub(2), old = old_ln }
          old_ln = old_ln + 1
          f.deletions = f.deletions + 1
        elseif c == " " or line == "" then
          h.lines[#h.lines + 1] = { kind = " ", text = line:sub(2), old = old_ln, new = new_ln }
          old_ln, new_ln = old_ln + 1, new_ln + 1
        elseif c == "\\" then
          -- "\ No newline at end of file": not a line of either side
        elseif line:match("^diff %-%-git ") then
          h = nil
        end
      end
    end
  end
  -- a trailing "" from the final newline lands as a bogus context line
  for _, file in ipairs(files) do
    local last = file.hunks[#file.hunks]
    local ll = last and last.lines[#last.lines]
    if ll and ll.kind == " " and ll.text == "" then table.remove(last.lines) end
  end
  return files
end

-- index(files) → { [path] = { RIGHT = { [line] = hunk_id }, LEFT = {…} } }
-- hunk ids are global ("<file>:<hunk>") so ranges can be checked.
function M.index(files)
  local idx = {}
  for fi, f in ipairs(files) do
    local m = { RIGHT = {}, LEFT = {} }
    for hi, h in ipairs(f.hunks) do
      local id = fi .. ":" .. hi
      for _, l in ipairs(h.lines) do
        if l.kind == "-" then m.LEFT[l.old] = id else m.RIGHT[l.new] = id end
      end
    end
    idx[f.path] = m
  end
  return idx
end

-- valid(idx, a) → true | false, reason. a = { path, side, line, start_line?, start_side? }
function M.valid(idx, a)
  local m = idx[a.path]
  if not m then return false, "file not in this diff" end
  local side = a.side or "RIGHT"
  local h = a.line and m[side] and m[side][a.line]
  if not h then return false, ("%s line %s is outside the diff's hunks"):format(side, tostring(a.line)) end
  if a.start_line then
    local ss = a.start_side or side
    local hs = m[ss] and m[ss][a.start_line]
    if not hs then return false, "the range starts outside the diff's hunks" end
    if hs ~= h then return false, "a range must stay within one hunk" end
  end
  return true
end

-- annotated(files, per_file, budget) → text for the AI prompt: each diff line
-- prefixed with its anchor (R<new> / L<old>) so the model never has to count.
function M.annotated(files, per_file, budget)
  per_file, budget = per_file or 400, budget or 4000
  local out, used, skipped = {}, 0, {}
  for _, f in ipairs(files) do
    if f.binary or #f.hunks == 0 then
      out[#out + 1] = ("### %s (%s, no textual diff)"):format(f.path, f.binary and "binary" or f.status)
    elseif used >= budget then
      skipped[#skipped + 1] = f.path
    else
      out[#out + 1] = ("### %s (%s)"):format(f.path, f.status)
      local n = 0
      for _, h in ipairs(f.hunks) do
        if n >= per_file or used >= budget then
          out[#out + 1] = "… (rest of this file truncated)"
          break
        end
        out[#out + 1] = h.header
        for _, l in ipairs(h.lines) do
          local tag = l.kind == "-" and ("L" .. l.old) or ("R" .. l.new)
          out[#out + 1] = ("%-6s %s%s"):format(tag, l.kind, l.text)
          n, used = n + 1, used + 1
        end
      end
      out[#out + 1] = ""
    end
  end
  if #skipped > 0 then out[#out + 1] = "Files not shown (budget): " .. table.concat(skipped, ", ") end
  return table.concat(out, "\n")
end

return M
