-- AI assistance through headless Claude (`claude -p --output-format json`).
-- Claude only ever produces drafts: a PR title/body that opens in a compose
-- buffer, or review findings that go into a drafts list. Posting is always a
-- separate `:w` or accept.
--
-- The prompt goes on stdin (diffs are too big for argv). The CLI answers with
-- one JSON envelope whose `result` is Claude's text; the JSON we asked for is
-- dug out of that text (models sometimes wrap it in a ``` fence).

local config = require("upstream.config")
local git = require("upstream.git")

local M = {}

local function opts() return config.options.ai end

-- Pull the first JSON object/array out of `text`.
function M.extract_json(text, want)
  text = (text or ""):gsub("^%s*```%w*%s*\n", ""):gsub("\n```%s*$", "")
  local open_ch = want == "array" and "[" or "{"
  local close_ch = want == "array" and "]" or "}"
  local s = text:find(open_ch, 1, true)
  if not s then return nil end
  -- try the longest candidate first, then shrink to earlier closing brackets
  local e = #text
  while e > s do
    local ce = text:sub(1, e):match(".*()%" .. close_ch)
    if not ce or ce <= s then break end
    local ok, v = pcall(vim.json.decode, text:sub(s, ce), { luanil = { object = true, array = true } })
    if ok and type(v) == "table" then return v end
    e = ce - 1
  end
  return nil
end

-- run(prompt, cb(err, text), { label = "drafting the PR" })
function M.run(prompt, cb, o)
  o = o or {}
  local cmd = { opts().command, "-p", "--output-format", "json" }
  vim.list_extend(cmd, opts().args or {})
  if vim.fn.executable(cmd[1]) == 0 then
    return cb(("`%s` not found; the AI features need Claude Code"):format(cmd[1]))
  end
  local started = vim.uv.now()
  vim.notify(("upstream: %s with %s…"):format(o.label or "asking", cmd[1]), vim.log.levels.INFO)
  local ok, err = pcall(vim.system, cmd, {
    text = true, stdin = prompt, cwd = vim.fn.getcwd(), timeout = opts().timeout,
  }, vim.schedule_wrap(function(res)
    if res.code == 124 then return cb(cmd[1] .. " timed out") end
    local okj, env = pcall(vim.json.decode, res.stdout or "", { luanil = { object = true, array = true } })
    if not okj or type(env) ~= "table" then
      local msg = vim.trim(res.stderr or "")
      return cb(msg ~= "" and msg or (cmd[1] .. " returned no JSON (exit " .. res.code .. ")"))
    end
    if env.is_error or env.subtype and env.subtype ~= "success" then
      return cb(tostring(env.result or env.subtype or "Claude reported an error"))
    end
    local secs = math.floor((vim.uv.now() - started) / 100) / 10
    vim.notify(("upstream: %s done (%ss)"):format(o.label or "Claude", secs), vim.log.levels.INFO)
    cb(nil, env.result or "")
  end))
  if not ok then cb(tostring(err)) end
end

-- ---------------------------------------------------------------------------
-- 1. draft PR
-- ---------------------------------------------------------------------------

local DRAFT_PR = [[
You are drafting a GitHub pull request for the changes below, in %s (%s → %s).

Reply with ONLY a JSON object, no prose and no code fence:
{"title": "...", "body": "..."}

- title: at most 72 characters, imperative mood. If the commits follow a
  convention (e.g. Conventional Commits like `feat(scope): …`), follow it.
- body: GitHub markdown. Start with 1–3 sentences on what changes and why,
  then a `## Changes` bullet list, then (only if useful) `## Notes for reviewers`.
  Don't invent issue numbers, benchmarks or test results.

## Commits (oldest first)
%s

## Diff stat
%s

## Diff (large files are truncated)
%s
]]

function M.draft_pr(repo, head, base, cb)
  git.base_ref(base, function(ref)
    git.commits(ref, function(err, commits)
      if err then return cb(err) end
      if #commits == 0 then return cb(("no commits on %s that aren't on %s"):format(head, ref)) end
      git.diff_for_prompt(ref, function(derr, diff, stat)
        if derr then return cb(derr) end
        local log = {}
        for _, c in ipairs(commits) do
          log[#log + 1] = "- " .. c.subject .. (c.body ~= "" and ("\n  " .. c.body:gsub("\n", "\n  ")) or "")
        end
        local prompt = DRAFT_PR:format(repo.full, head, base, table.concat(log, "\n"), stat, diff)
        M.run(prompt, function(rerr, text)
          if rerr then return cb(rerr) end
          local d = M.extract_json(text, "object")
          if type(d) ~= "table" or type(d.title) ~= "string" then
            return cb("Claude's answer wasn't the expected {title, body} JSON")
          end
          cb(nil, { title = vim.trim(d.title), body = type(d.body) == "string" and d.body or "" })
        end, { label = "drafting the PR" })
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- 2. review assist
-- ---------------------------------------------------------------------------

local REVIEW = [[
You are reviewing GitHub pull request #%d in %s: %s

## Description
%s
%s
## Diff
Each diff line is prefixed with its anchor: `R<n>` is line n of the NEW file
(added `+` or context lines), `L<n>` is line n of the OLD file (removed `-`
lines). Files may be truncated.

%s

Review for correctness bugs, security problems, missing edge cases and
clear maintainability issues. Skip pure style nitpicks unless they matter.
Reply with ONLY a JSON array (no prose, no code fence), at most %d items:
[{"path": "file/path", "line": 42, "side": "RIGHT", "start_line": 40,
  "severity": "high" | "medium" | "low" | "nit", "body": "markdown comment"}]

- `side` is "RIGHT" for R anchors and "LEFT" for L anchors; `line` is the
  anchor's number. Only use anchors that appear in the diff above.
- `start_line` (optional) starts a multi-line range on the same side, in the
  same hunk, before `line`.
- `body` is the comment as you'd post it: specific, actionable, and include
  a ```suggestion block when the fix is small.
- Reply `[]` if there's nothing worth commenting on.
]]

-- review(ctx, cb(err, findings)); ctx = { repo, number, title, body,
-- closes = { {number, title, body} }, annotated = string }
function M.review(ctx, cb)
  local linked = {}
  for _, i in ipairs(ctx.closes or {}) do
    linked[#linked + 1] = ("\n## Linked issue #%d: %s\n%s\n"):format(i.number, i.title or "", i.body or "")
  end
  local prompt = REVIEW:format(ctx.number, ctx.repo.full, ctx.title or "",
    vim.trim(ctx.body or "") ~= "" and ctx.body or "(none)", table.concat(linked), ctx.annotated,
    opts().max_findings)
  M.run(prompt, function(err, text)
    if err then return cb(err) end
    local list = M.extract_json(text, "array")
    if type(list) ~= "table" then return cb("Claude's answer wasn't a JSON array of findings") end
    local out = {}
    for _, f in ipairs(list) do
      if type(f) == "table" and type(f.path) == "string" and type(f.body) == "string" then
        out[#out + 1] = {
          path = f.path,
          line = tonumber(f.line),
          side = (f.side == "LEFT") and "LEFT" or "RIGHT",
          start_line = tonumber(f.start_line),
          severity = type(f.severity) == "string" and f.severity:lower() or "medium",
          body = f.body,
        }
      end
    end
    cb(nil, out)
  end, { label = "reviewing #" .. ctx.number })
end

-- ---------------------------------------------------------------------------
-- 3. work on an issue
-- ---------------------------------------------------------------------------

local function default_open_chat(prompt, _ctx)
  vim.cmd.tabnew()
  local cmd = { opts().command, prompt }
  if vim.fn.has("nvim-0.11") == 1 then
    vim.fn.jobstart(cmd, { term = true })
  else
    vim.fn.termopen(cmd)
  end
  vim.cmd.startinsert()
end

local function issue_prompt(repo, it)
  local out = {
    ("Let's work on GitHub issue #%d in %s: %s"):format(it.number, repo.full, it.title or ""),
    "",
    vim.trim(it.body or "") ~= "" and it.body or "(no description)",
  }
  local comments = vim.tbl_filter(function(t) return t.type == "comment" end, it.timeline or {})
  if #comments > 0 then
    out[#out + 1] = ""
    out[#out + 1] = "Comments:"
    for _, c in ipairs(comments) do
      out[#out + 1] = ("- @%s: %s"):format(c.author, (c.body or ""):gsub("\r", ""):gsub("\n", "\n  "))
    end
  end
  out[#out + 1] = ""
  out[#out + 1] = "Start by finding the relevant code and proposing a plan before changing anything."
  return table.concat(out, "\n")
end

-- work_on(repo, detail_item): optional `git switch -c <n>-<slug>`, then a chat
-- seeded with the issue (or PR) through setup({ ai = { open_chat = fn } }).
function M.work_on(repo, it)
  local prompt = issue_prompt(repo, it)
  local function go()
    local ui = require("upstream.ui")
    if ui.is_open() then ui.close() end
    local fn = opts().open_chat or default_open_chat
    fn(prompt, { repo = repo.full, number = it.number, kind = it.kind, title = it.title, url = it.url })
  end
  if it.kind ~= "issue" then return go() end
  local actions = require("upstream.actions")
  local branch = actions.branch_name(it)
  local c = vim.fn.confirm(("Work on #%d — switch to branch %s first?"):format(it.number, branch),
    "&Branch\n&Stay on this branch\n&Cancel", 1, "Question")
  if c == 1 then
    actions.start_branch(repo, it, function(err)
      if not err then go() end
    end)
  elseif c == 2 then
    go()
  end
end

return M
