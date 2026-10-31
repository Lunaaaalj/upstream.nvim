-- Manage: comment, edit, close/reopen, labels, assignees, reviewers,
-- milestone, merge, check out, delete branch, new issue, new PR.
--
-- Every function takes the repo and a (list or detail) item. Writes need the
-- node id, which only the detail query carries, so `ensure` fetches the
-- detail first when the cache doesn't have it. Mutations return the full
-- detail, which data.apply() writes to the cache and announces with
-- `User UpstreamChanged` (data.item), so the float updates without refetching.
--
-- Nothing is posted without a `:w` in a compose buffer or a confirmation.

local compose = require("upstream.compose")
local data = require("upstream.data")
local gh = require("upstream.gh")
local git = require("upstream.git")
local pick = require("upstream.ui.pick")
local queries = require("upstream.queries")

local M = {}

local function info(msg) vim.notify("upstream: " .. msg, vim.log.levels.INFO) end
local function warn(msg) vim.notify("upstream: " .. msg, vim.log.levels.WARN) end

local function confirm(msg, choices, default)
  return vim.fn.confirm(msg, choices or "&Yes\n&No", default or 1, "Question")
end

-- the float closes for compose buffers and reopens once they're submitted
local function leave_float()
  local ui = require("upstream.ui")
  local was = ui.is_open()
  if was then ui.close() end
  return was
end

local function reopen(was, opts)
  if was then require("upstream.ui").open(opts) end
end

-- ensure(repo, it, fn(detail)): fn gets the detail item (with id)
function M.ensure(repo, it, fn)
  if it.id and it.body ~= nil then return fn(it) end
  local c = require("upstream.cache").read(repo, it.kind .. "-" .. it.number)
  if c and c.id then return fn(c) end
  data.detail(repo, it.kind, it.number, function(err, d)
    if not err and d and d.id then fn(d) end
  end, true)
end

local function update_query(it) return it.kind == "pr" and queries.update_pr or queries.update_issue end
local function update_path(it) return it.kind == "pr" and { "updatePullRequest", "pullRequest" } or { "updateIssue", "issue" } end

local function label(it) return (it.kind == "pr" and "PR #" or "#") .. it.number end

-- ---------------------------------------------------------------------------
-- compose: comment / edit
-- ---------------------------------------------------------------------------

function M.comment(repo, it, opts)
  opts = opts or {}
  M.ensure(repo, it, function(d)
    local was = opts.split and false or leave_float()
    compose.open(repo, {
      key = d.kind .. "-" .. d.number .. "-comment",
      title = "comment on " .. label(d),
      body = opts.body,
      split = opts.split,
      submit = function(_, body, done)
        if body == "" then return done("the comment is empty") end
        data.mutate(repo, queries.add_comment, { id = d.id, body = body }, { "addComment", "subject" }, done, true)
      end,
      on_done = function()
        info("commented on " .. label(d))
        reopen(was)
      end,
    })
  end)
end

function M.edit(repo, it)
  M.ensure(repo, it, function(d)
    local was = leave_float()
    local header = { { { "title", d.title } } }
    local keys = { "title" }
    if d.kind == "pr" then
      header[2] = { { "base", d.base } }
      keys[2] = "base"
    end
    compose.open(repo, {
      key = d.kind .. "-" .. d.number .. "-edit",
      title = "edit " .. label(d),
      header = header,
      keys = keys,
      body = d.body,
      submit = function(f, body, done)
        if (f.title or "") == "" then return done("the title is empty") end
        local vars = { id = d.id, title = f.title, body = body }
        if d.kind == "pr" and f.base and f.base ~= "" and f.base ~= d.base then vars.base = f.base end
        data.mutate(repo, update_query(d), vars, update_path(d), function(err) done(err) end, true)
      end,
      on_done = function()
        info("updated " .. label(d))
        reopen(was)
      end,
    })
  end)
end

-- ---------------------------------------------------------------------------
-- state
-- ---------------------------------------------------------------------------

function M.toggle_state(repo, it)
  M.ensure(repo, it, function(d)
    if d.state == "MERGED" then return warn(label(d) .. " is merged") end
    local closing = d.state == "OPEN"
    if confirm(("%s %s %s?"):format(closing and "Close" or "Reopen", label(d), d.title)) ~= 1 then return end
    local q, path
    if d.kind == "pr" then
      q, path = closing and queries.close_pr or queries.reopen_pr,
        { closing and "closePullRequest" or "reopenPullRequest", "pullRequest" }
    else
      q, path = closing and queries.close_issue or queries.reopen_issue,
        { closing and "closeIssue" or "reopenIssue", "issue" }
    end
    data.mutate(repo, q, { id = d.id }, path, function(err)
      if not err then info((closing and "closed " or "reopened ") .. label(d)) end
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- labels / assignees / reviewers / milestone
-- ---------------------------------------------------------------------------

function M.labels(repo, it)
  M.ensure(repo, it, function(d)
    data.meta(repo, function(err, meta)
      if err then return end
      local have = {}
      for _, l in ipairs(d.labels or {}) do have[l.name] = true end
      local items = {}
      for _, l in ipairs(meta.labels) do
        items[#items + 1] = { label = l.name, desc = l.description, selected = have[l.name], value = l.id }
      end
      pick.open({ title = "Labels · " .. label(d), multi = true, items = items }, function(chosen)
        if not chosen then return end
        local ids = vim.tbl_map(function(x) return x.value end, chosen)
        data.mutate(repo, update_query(d), { id = d.id, labelIds = ids }, update_path(d))
      end)
    end)
  end)
end

function M.assignees(repo, it)
  M.ensure(repo, it, function(d)
    data.meta(repo, function(err, meta)
      if err then return end
      local have = {}
      for _, a in ipairs(d.assignees or {}) do have[a] = true end
      local items = {}
      for _, u in ipairs(meta.users) do
        items[#items + 1] = { label = u.login, desc = u.name, selected = have[u.login], value = u.id }
      end
      pick.open({ title = "Assignees · " .. label(d), multi = true, items = items }, function(chosen)
        if not chosen then return end
        local ids = vim.tbl_map(function(x) return x.value end, chosen)
        data.mutate(repo, update_query(d), { id = d.id, assigneeIds = ids }, update_path(d))
      end)
    end)
  end)
end

function M.reviewers(repo, it)
  if it.kind ~= "pr" then return warn("reviewers are for pull requests") end
  M.ensure(repo, it, function(d)
    data.meta(repo, function(err, meta)
      if err then return end
      local have, teams = {}, {}
      for _, r in ipairs(d.reviewers or {}) do
        if type(r) == "table" then
          if r.team then teams[#teams + 1] = r.id else have[r.name] = true end
        end
      end
      local items = {}
      for _, u in ipairs(meta.users) do
        -- GitHub refuses a review request for the PR's own author
        if u.login ~= d.author then
          items[#items + 1] = { label = u.login, desc = u.name, selected = have[u.login], value = u.id }
        end
      end
      pick.open({ title = "Reviewers · " .. label(d), multi = true, items = items }, function(chosen)
        if not chosen then return end
        local ids = vim.tbl_map(function(x) return x.value end, chosen)
        -- union = false replaces the set; requested teams are passed back as-is
        data.mutate(repo, queries.request_reviews, { id = d.id, userIds = ids, teamIds = teams },
          { "requestReviews", "pullRequest" })
      end)
    end)
  end)
end

function M.milestone(repo, it)
  M.ensure(repo, it, function(d)
    data.meta(repo, function(err, meta)
      if err then return end
      local items = { { label = "(none)", value = vim.NIL, desc = d.milestone and "clear" or nil } }
      for _, m in ipairs(meta.milestones) do
        items[#items + 1] = { label = m.title, value = m.id, desc = m.title == d.milestone and "current" or nil }
      end
      pick.open({ title = "Milestone · " .. label(d), items = items }, function(choice)
        if not choice then return end
        -- vim.NIL encodes as an explicit null, which clears the milestone
        -- (an absent variable would mean "leave it alone")
        data.mutate(repo, update_query(d), { id = d.id, milestoneId = choice.value }, update_path(d))
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- merge / branches
-- ---------------------------------------------------------------------------

function M.delete_branch(repo, d)
  if d.cross_repo then return warn("the branch lives in a fork; it can't be deleted from here") end
  if not d.head_ref_id then return info("branch " .. (d.head or "?") .. " is already gone") end
  if confirm(("Delete the remote branch %s?"):format(d.head)) ~= 1 then return end
  gh.graphql(queries.delete_ref, { id = d.head_ref_id }, function(err)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    info("deleted branch " .. d.head)
    data.detail(repo, "pr", d.number, function() end, true)
  end)
end

local METHODS = { "MERGE", "SQUASH", "REBASE" }

function M.merge(repo, it)
  if it.kind ~= "pr" then return warn("only pull requests can be merged") end
  M.ensure(repo, it, function(d)
    if d.state ~= "OPEN" then
      if d.head_ref_id and not d.cross_repo then return M.delete_branch(repo, d) end
      return info(label(d) .. " is " .. d.state:lower())
    end
    if d.draft then
      if confirm(label(d) .. " is a draft. Mark it ready for review?") == 1 then
        data.mutate(repo, queries.mark_ready, { id = d.id }, { "markPullRequestReadyForReview", "pullRequest" })
      end
      return
    end
    if d.mergeable == "CONFLICTING" then
      local msg = ("%s has merge conflicts with %s and can't be merged.\nCheck it out and merge %s into it to resolve them locally?")
        :format(label(d), d.base or "the base", d.base or "the base")
      if confirm(msg, "&Resolve locally\n&Cancel", 2) == 1 then M.resolve_conflicts(repo, d) end
      return
    end
    local extra = ""
    if d.checks == "FAILURE" or d.checks == "ERROR" then extra = " (checks are failing)" end
    if d.checks == "PENDING" then extra = " (checks are still running)" end
    local choice = confirm(("Merge %s into %s%s?"):format(label(d), d.base or "?", extra),
      "&Merge commit\n&Squash\n&Rebase\n&Cancel", 4)
    local method = METHODS[choice]
    if not method then return end
    data.mutate(repo, queries.merge_pr, { id = d.id, method = method }, { "mergePullRequest", "pullRequest" },
      function(err, merged)
        if err or not merged then return end
        info(("merged %s (%s)"):format(label(d), method:lower()))
        if merged.head_ref_id and not merged.cross_repo then M.delete_branch(repo, merged) end
      end)
  end)
end

function M.checkout(repo, it)
  if it.kind ~= "pr" then return warn("only pull requests can be checked out") end
  if confirm(("Check out %s (%s) here?"):format(label(it), it.head or "?")) ~= 1 then return end
  gh.run({ "pr", "checkout", tostring(it.number), "-R", repo.full }, function(err)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    info("checked out " .. label(it))
    vim.cmd.checktime()
    data.touch(repo, "branch")
  end, { cwd = vim.fn.getcwd(), timeout = 60000 })
end

-- A conflicting PR can't be merged on GitHub, so bring it up to date here:
-- check out the PR branch (`gh pr checkout` fast-forwards it to its remote
-- head), fetch the base, and merge it in. Conflicts are left in the working
-- tree, listed in the quickfix list, for the user to resolve, commit and push.
function M.resolve_conflicts(repo, d)
  local err_ = function(e) vim.notify("upstream: " .. e, vim.log.levels.ERROR) end
  local base = d.base
  if not base then return warn("unknown base branch for " .. label(d)) end
  git.dirty(function(err, dirty)
    if err then return err_(err) end
    if dirty then return warn("the working tree has uncommitted changes; commit or stash them first") end
    info(("checking out %s…"):format(label(d)))
    gh.run({ "pr", "checkout", tostring(d.number), "-R", repo.full }, function(cerr)
      if cerr then return err_(cerr) end
      data.touch(repo, "branch")
      git.remote_for(repo.full, function(remote)
        local ref = remote .. "/" .. base
        git.run({ "fetch", remote, base }, function(ferr)
          if ferr then return err_(ferr) end
          git.run({ "merge", "--no-edit", ref }, function(merr)
            vim.cmd.checktime()
            if not merr then
              return info(("merged %s into %s cleanly; push to update %s"):format(ref, d.head or "the branch", label(d)))
            end
            git.conflicts(function(files)
              if #files == 0 then return err_(merr) end
              local root = vim.fn.getcwd()
              vim.fn.setqflist({}, " ", {
                title = ("upstream: %s conflicts with %s"):format(label(d), ref),
                items = vim.tbl_map(function(f)
                  return { filename = root .. "/" .. f, lnum = 1, text = "merge conflict" }
                end, files),
              })
              leave_float()
              vim.cmd("botright copen")
              warn(("%d file%s conflict with %s. Resolve them, then `git commit` and push (or `git merge --abort`)")
                :format(#files, #files == 1 and "" or "s", ref))
            end)
          end, 30000)
        end, 60000)
      end)
    end, { cwd = vim.fn.getcwd(), timeout = 60000 })
  end)
end

-- ---------------------------------------------------------------------------
-- create
-- ---------------------------------------------------------------------------

-- names → ids through meta; cb(err, ids)
local function resolve(names, pool, field)
  local by, ids, missing = {}, {}, {}
  for _, x in ipairs(pool) do by[x[field]:lower()] = x.id end
  for _, n in ipairs(names) do
    local id = by[n:lower()]
    if id then ids[#ids + 1] = id else missing[#missing + 1] = n end
  end
  return ids, missing
end

local function resolve_fields(meta, f)
  local labels, ml = resolve(compose.list(f.labels), meta.labels, "name")
  local users, mu = resolve(compose.list(f.assignees), meta.users, "login")
  if #ml > 0 then return nil, "unknown label(s): " .. table.concat(ml, ", ") end
  if #mu > 0 then return nil, "unknown assignee(s): " .. table.concat(mu, ", ") end
  local ms
  if f.milestone and f.milestone ~= "" then
    for _, m in ipairs(meta.milestones) do
      if m.title:lower() == f.milestone:lower() then ms = m.id end
    end
    if not ms then return nil, "unknown milestone: " .. f.milestone end
  end
  return { labelIds = #labels > 0 and labels or nil, assigneeIds = #users > 0 and users or nil, milestoneId = ms }
end

function M.new_issue(repo, opts)
  opts = opts or {}
  local was = leave_float()
  compose.open(repo, {
    key = "new-issue",
    title = "new issue",
    header = { { { "title", opts.title or "" } }, { { "labels", "" } }, { { "assignees", "" } }, { { "milestone", "" } } },
    keys = { "title", "labels", "assignees", "milestone" },
    body = opts.body,
    submit = function(f, body, done)
      if (f.title or "") == "" then return done("the title is empty") end
      data.meta(repo, function(err, meta)
        if err then return done(err) end
        local ids, rerr = resolve_fields(meta, f)
        if not ids then return done(rerr) end
        local vars = vim.tbl_extend("force", ids, { repo = meta.id, title = f.title, body = body })
        data.mutate(repo, queries.create_issue, vars, { "createIssue", "issue" }, function(e, created)
          if not e and created then info(("opened #%d %s"):format(created.number, created.title)) end
          done(e)
        end, true)
      end)
    end,
    on_done = function() reopen(was or opts.reopen, { tab = "issues" }) end,
  })
end

-- Push the head branch when it has no upstream or is ahead of it (asks first).
local function ensure_pushed(head, cb)
  git.upstream_state(function(has, ahead)
    if has and ahead == 0 then return cb(nil) end
    local msg = has and ("%s is %d commit%s ahead of its remote. Push it first?"):format(head, ahead, ahead == 1 and "" or "s")
      or ("%s isn't on GitHub yet. Push it to origin?"):format(head)
    local c = confirm(msg, "&Push\n&Skip\n&Cancel")
    if c == 3 or c == 0 then return cb("cancelled") end
    if c == 2 then return cb(nil) end
    info("pushing " .. head .. "…")
    git.push(head, function(err) cb(err) end)
  end)
end

-- new_pr(repo, { title, body, draft, ai }) — compose a PR from the current branch
function M.new_pr(repo, opts)
  opts = opts or {}
  git.branch(function(err, head)
    if err or not head then return warn("not on a branch") end
    local base = repo.default_branch
    if head == base then return warn(("you're on %s; switch to a feature branch first"):format(base)) end

    local function open(title, body)
      local was = leave_float()
      compose.open(repo, {
        key = "new-pr-" .. head,
        title = "new PR " .. head .. " → " .. base,
        header = {
          { { "title", title or "" } },
          { { "base", base }, { "head", head }, { "draft", opts.draft and "true" or "false" } },
          { { "labels", "" } },
          { { "assignees", "" } },
        },
        keys = { "title", "base", "head", "draft", "labels", "assignees" },
        body = body,
        submit = function(f, b, done)
          if (f.title or "") == "" then return done("the title is empty") end
          local fhead = f.head ~= "" and f.head or head
          ensure_pushed(fhead, function(perr)
            if perr then return done(perr) end
            data.meta(repo, function(merr, meta)
              if merr then return done(merr) end
              local ids, rerr = resolve_fields(meta, f)
              if not ids then return done(rerr) end
              local vars = { repo = meta.id, base = f.base ~= "" and f.base or base, head = fhead,
                             title = f.title, body = b, draft = compose.bool(f.draft) }
              data.mutate(repo, queries.create_pr, vars, { "createPullRequest", "pullRequest" }, function(e, pr)
                if e or not pr then return done(e or "no pull request returned") end
                info(("opened PR #%d %s"):format(pr.number, pr.title))
                if ids.labelIds or ids.assigneeIds then
                  data.mutate(repo, queries.update_pr,
                    { id = pr.id, labelIds = ids.labelIds, assigneeIds = ids.assigneeIds },
                    { "updatePullRequest", "pullRequest" })
                end
                done(nil)
              end, true)
            end)
          end)
        end,
        on_done = function() reopen(true, { tab = "prs" }) end,
      })
      return was
    end

    if opts.title or opts.body then return open(opts.title, opts.body) end
    if opts.ai then
      return require("upstream.ai").draft_pr(repo, head, base, function(aerr, draft)
        if aerr then return vim.notify("upstream: " .. aerr, vim.log.levels.ERROR) end
        open(draft.title, draft.body)
      end)
    end
    -- no AI: one commit → its subject/body; several → a bullet list
    git.base_ref(base, function(ref)
      git.commits(ref, function(cerr, commits)
        commits = cerr and {} or commits
        if #commits == 1 then return open(commits[1].subject, commits[1].body) end
        local title = head:gsub("^%w+/", ""):gsub("[-_]", " ")
        local lines = {}
        for _, c in ipairs(commits) do lines[#lines + 1] = "- " .. c.subject end
        open(title, table.concat(lines, "\n"))
      end)
    end)
  end)
end

return M
