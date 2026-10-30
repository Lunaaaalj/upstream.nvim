-- Data layer: one fetch per tab (paginated) and one per detail item, served
-- stale-while-revalidate. A call gives `cb(nil, cached, { stale = true })`
-- straight away when a cache file exists, then refetches and gives
-- `cb(nil, fresh, { stale = false })`. Every fresh result fires a debounced
-- `User UpstreamChanged`.
--
-- Items are normalised into one flat shape so the list and detail renderers
-- don't care which query (or tab) produced them:
--   { kind = "issue"|"pr"|"run", number, title, state, url, author, updated,
--     comments, labels = { {name, color} }, draft, checks, review, head, base }

local cache = require("upstream.cache")
local config = require("upstream.config")
local gh = require("upstream.gh")
local queries = require("upstream.queries")

local M = {}

M.tabs = { "issues", "prs", "reviews", "actions" }
M.states = { "open", "closed", "all" }

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------

local emit_pending = false
local function changed(repo, key)
  if emit_pending then return end
  emit_pending = true
  vim.defer_fn(function()
    emit_pending = false
    vim.api.nvim_exec_autocmds("User", {
      pattern = "UpstreamChanged",
      modeline = false,
      data = { repo = repo.full, key = key },
    })
  end, 80)
end

-- ---------------------------------------------------------------------------
-- normalisation
-- ---------------------------------------------------------------------------

local function labels(node)
  local out = {}
  for _, l in ipairs(vim.tbl_get(node, "labels", "nodes") or {}) do
    out[#out + 1] = { name = l.name, color = l.color }
  end
  return out
end

local function login(t)
  return t and (t.login or t.name) or "ghost"
end

local function item(node)
  if type(node) ~= "table" or not node.number then return nil end
  local pr = node.__typename == "PullRequest"
  local commit = vim.tbl_get(node, "commits", "nodes", 1, "commit")
  return {
    kind = pr and "pr" or "issue",
    number = node.number,
    title = node.title,
    state = node.state, -- OPEN / CLOSED / MERGED
    url = node.url,
    author = login(node.author),
    updated = node.updatedAt,
    created = node.createdAt,
    comments = vim.tbl_get(node, "comments", "totalCount") or 0,
    labels = labels(node),
    draft = node.isDraft or nil,
    head = node.headRefName,
    base = node.baseRefName,
    review = node.reviewDecision,
    checks = commit and vim.tbl_get(commit, "statusCheckRollup", "state") or nil,
  }
end

local function run_item(r)
  return {
    kind = "run",
    number = r.databaseId,
    title = r.displayTitle,
    workflow = r.workflowName,
    status = r.status, -- queued / in_progress / completed
    conclusion = r.conclusion, -- success / failure / cancelled / skipped …
    state = r.status == "completed" and "CLOSED" or "OPEN",
    head = r.headBranch,
    event = r.event,
    created = r.createdAt,
    updated = r.createdAt,
    url = r.url,
    labels = {},
  }
end

-- ---------------------------------------------------------------------------
-- fetch helpers
-- ---------------------------------------------------------------------------

-- Requests for the same key share one gh call.
local inflight = {}
local function once(key, start, cb)
  if inflight[key] then
    table.insert(inflight[key], cb)
    return
  end
  inflight[key] = { cb }
  start(function(...)
    local cbs = inflight[key]
    inflight[key] = nil
    for _, f in ipairs(cbs) do f(...) end
  end)
end

local ISSUE_STATES = { open = { "OPEN" }, closed = { "CLOSED" } }
local PR_STATES = { open = { "OPEN" }, closed = { "CLOSED", "MERGED" } }

local function fetch_page(repo, tab, state, cursor, done)
  local n = math.min(config.options.per_page, 100)
  local function page(err, conn)
    if err then return done(err) end
    if not conn then return done("unexpected response") end
    local items = {}
    for _, node in ipairs(conn.nodes or {}) do items[#items + 1] = item(node) end
    done(nil, {
      items = items,
      total = conn.totalCount,
      has_next = vim.tbl_get(conn, "pageInfo", "hasNextPage") or false,
      cursor = vim.tbl_get(conn, "pageInfo", "endCursor"),
    })
  end

  if tab == "issues" or tab == "prs" then
    local vars = { owner = repo.owner, name = repo.name, n = n, cursor = cursor,
                   states = (tab == "issues" and ISSUE_STATES or PR_STATES)[state] }
    gh.graphql(queries[tab], vars, function(err, d) page(err, d and vim.tbl_get(d, "repository", "items")) end)
  elseif tab == "reviews" then
    local q = ("repo:%s is:pr review-requested:@me sort:updated-desc"):format(repo.full)
    if state ~= "all" then q = q .. " is:" .. state end
    gh.graphql(queries.reviews, { q = q, n = n, cursor = cursor }, function(err, d)
      page(err, d and d.items)
    end)
  elseif tab == "actions" then
    -- no workflow-run listing in GraphQL, and `gh run list` has no cursor:
    -- the "cursor" is how many runs were already fetched, and the next page
    -- asks for that many more and keeps only the new tail
    local skip = tonumber(cursor) or 0
    local limit = skip + n
    local fields = "databaseId,displayTitle,workflowName,status,conclusion,headBranch,event,createdAt,url"
    local args = { "run", "list", "-R", repo.full, "-L", tostring(limit), "--json", fields }
    -- "open" = not finished yet; gh takes only one --status, so filter here
    gh.json(args, function(err, runs)
      if err then return done(err) end
      local items = {}
      for i, r in ipairs(runs or {}) do
        local it = run_item(r)
        if i > skip and (state == "all" or (state == "open") == (it.state == "OPEN")) then items[#items + 1] = it end
      end
      local full = #(runs or {}) >= limit
      done(nil, { items = items, total = nil, has_next = full, cursor = full and tostring(limit) or nil })
    end)
  end
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

-- list(repo, tab, state, cursor, cb, force): cb(err, page, meta).
-- Only the first page is cached; later pages (cursor ~= nil) are fetched live.
function M.list(repo, tab, state, cursor, cb, force)
  local key = tab .. "-" .. state
  if not cursor and not force then
    local c = cache.read(repo, key)
    if c then cb(nil, c, { stale = true }) end
  end
  once(repo.full .. ":" .. key .. ":" .. (cursor or ""), function(done)
    fetch_page(repo, tab, state, cursor, done)
  end, function(err, page)
    if err then
      gh.notify_once(err)
      return cb(err)
    end
    if not cursor then cache.write(repo, key, page) end
    cb(nil, page, { stale = false })
    changed(repo, key)
  end)
end

local function timeline(node)
  local out = {}
  for _, t in ipairs(vim.tbl_get(node, "timelineItems", "nodes") or {}) do
    local typ = t.__typename
    if typ == "IssueComment" then
      out[#out + 1] = { type = "comment", author = login(t.author), at = t.createdAt, body = t.body }
    elseif typ == "PullRequestReview" then
      out[#out + 1] = { type = "review", author = login(t.author), at = t.createdAt, body = t.body, state = t.state }
    elseif typ == "PullRequestCommit" then
      local c = t.commit or {}
      out[#out + 1] = {
        type = "commit", at = c.committedDate, oid = c.abbreviatedOid, body = c.messageHeadline,
        author = vim.tbl_get(c, "author", "user", "login") or vim.tbl_get(c, "author", "name") or "?",
      }
    elseif typ == "ClosedEvent" or typ == "ReopenedEvent" or typ == "MergedEvent" then
      out[#out + 1] = { type = typ:gsub("Event$", ""):lower(), author = login(t.actor), at = t.createdAt }
    elseif typ == "CrossReferencedEvent" and t.source and t.source.number then
      out[#out + 1] = {
        type = "reference", author = login(t.actor), at = t.createdAt,
        ref = { number = t.source.number, title = t.source.title, pr = t.source.__typename == "PullRequest" },
      }
    end
  end
  return out
end

local function detail_item(node)
  local it = item(node)
  if not it then return nil end
  it.body = node.body
  it.assignees = vim.tbl_map(login, vim.tbl_get(node, "assignees", "nodes") or {})
  it.milestone = vim.tbl_get(node, "milestone", "title")
  it.timeline = timeline(node)
  it.timeline_total = vim.tbl_get(node, "timelineItems", "totalCount") or #it.timeline
  it.id = node.id
  if it.kind == "pr" then
    it.additions, it.deletions, it.files = node.additions, node.deletions, node.changedFiles
    it.head_oid = node.headRefOid
    it.head_ref_id = vim.tbl_get(node, "headRef", "id")
    it.cross_repo = node.isCrossRepository
    it.mergeable = node.mergeable
    it.approvals = vim.tbl_get(node, "approvals", "totalCount") or 0
    it.commit_count = vim.tbl_get(node, "commits", "totalCount")
    it.closes = vim.tbl_get(node, "closingIssuesReferences", "nodes") or {}
    it.reviewers = {}
    for _, r in ipairs(vim.tbl_get(node, "reviewRequests", "nodes") or {}) do
      local rr = r.requestedReviewer or {}
      it.reviewers[#it.reviewers + 1] = { name = login(rr), id = rr.id, team = rr.__typename == "Team" }
    end
  end
  return it
end

local function run_detail(repo, number, done)
  local fields = "databaseId,displayTitle,workflowName,status,conclusion,headBranch,event,createdAt,url,jobs"
  gh.json({ "run", "view", tostring(number), "-R", repo.full, "--json", fields }, function(err, r)
    if err then return done(err) end
    if type(r) ~= "table" or not r.databaseId then return done("run " .. number .. " not found") end
    local it = run_item(r)
    it.jobs = {}
    for _, j in ipairs(r.jobs or {}) do
      local steps = {}
      for _, st in ipairs(j.steps or {}) do
        steps[#steps + 1] = { name = st.name, status = st.status, conclusion = st.conclusion }
      end
      it.jobs[#it.jobs + 1] = {
        name = j.name, status = j.status, conclusion = j.conclusion, id = j.databaseId,
        started = j.startedAt, completed = j.completedAt, steps = steps,
      }
    end
    done(nil, it)
  end)
end

-- detail(repo, kind, number, cb, force): cb(err, item, meta). Runs come from
-- `gh run view` (jobs and steps); issues and PRs from GraphQL.
function M.detail(repo, kind, number, cb, force)
  local key = kind .. "-" .. number
  if not force then
    local c = cache.read(repo, key)
    if c then cb(nil, c, { stale = true }) end
  end
  once(repo.full .. ":" .. key, function(done)
    if kind == "run" then return run_detail(repo, number, done) end
    gh.graphql(queries[kind], { owner = repo.owner, name = repo.name, number = number }, function(err, d)
      if err then return done(err) end
      local it = detail_item(d and vim.tbl_get(d, "repository", "item"))
      if not it then return done("#" .. number .. " not found") end
      done(nil, it)
    end)
  end, function(err, it)
    if err then
      gh.notify_once(err)
      return cb(err)
    end
    cache.write(repo, key, it)
    cb(nil, it, { stale = false })
    changed(repo, key)
  end)
end

-- apply(repo, node): a mutation's returned issue/PR node → normalised item,
-- written to the detail cache. Fires `User UpstreamChanged` straight away
-- (not debounced) with `data.item`, which the float uses to patch its lists.
function M.apply(repo, node)
  local it = detail_item(node)
  if not it then return nil end
  cache.write(repo, it.kind .. "-" .. it.number, it)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "UpstreamChanged",
    modeline = false,
    data = { repo = repo.full, key = it.kind .. "-" .. it.number, item = it },
  })
  return it
end

-- mutate(repo, query, vars, path, cb, quiet): run a mutation, dig the
-- issue/PR node out of the payload at `path` (e.g. { "addComment", "subject" })
-- and apply it. cb(err, item). Errors are notified (a write failing silently
-- is worse than a noisy one) unless `quiet`: compose buffers report their own,
-- with the draft's path.
function M.mutate(repo, query, vars, path, cb, quiet)
  cb = cb or function() end
  gh.graphql(query, vars, function(err, d)
    if err then
      if not quiet then vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
      return cb(err)
    end
    local node = path and vim.tbl_get(d or {}, unpack(path))
    cb(nil, node and M.apply(repo, node) or nil, d)
  end)
end

-- events for things that aren't an issue/PR node (threads, runs, branches)
function M.touch(repo, key) changed(repo, key) end

-- meta(repo, cb, force): labels / assignable users / milestones / repo id /
-- viewer login, kept in memory for a few minutes.
local metas = {}
local META_TTL = 300
function M.meta(repo, cb, force)
  local m = metas[repo.full]
  if m and not force and os.time() - m.at < META_TTL then return cb(nil, m) end
  once(repo.full .. ":meta", function(done)
    gh.graphql(queries.meta, { owner = repo.owner, name = repo.name }, function(err, d)
      if err then return done(err) end
      local r = d and d.repository or {}
      done(nil, {
        at = os.time(),
        id = r.id,
        viewer = vim.tbl_get(d, "viewer", "login"),
        labels = vim.tbl_get(r, "labels", "nodes") or {},
        users = vim.tbl_get(r, "assignableUsers", "nodes") or {},
        milestones = vim.tbl_get(r, "milestones", "nodes") or {},
      })
    end)
  end, function(err, meta)
    if err then
      vim.notify("upstream: " .. err, vim.log.levels.ERROR)
      return cb(err)
    end
    metas[repo.full] = meta
    cb(nil, meta)
  end)
end

-- header(repo, cb): cb(err, { issues, prs, ci }) for the title's counts.
function M.header(repo, cb, force)
  if not force then
    local c = cache.read(repo, "header")
    if c then cb(nil, c, { stale = true }) end
  end
  once(repo.full .. ":header", function(done)
    gh.graphql(queries.header, { owner = repo.owner, name = repo.name }, function(err, d)
      if err then return done(err) end
      local r = d and d.repository or {}
      done(nil, {
        issues = vim.tbl_get(r, "issues", "totalCount") or 0,
        prs = vim.tbl_get(r, "pullRequests", "totalCount") or 0,
        ci = vim.tbl_get(r, "defaultBranchRef", "target", "statusCheckRollup", "state"),
      })
    end)
  end, function(err, h)
    if err then return cb(err) end -- the list fetch already reports errors
    cache.write(repo, "header", h)
    cb(nil, h, { stale = false })
  end)
end

return M
