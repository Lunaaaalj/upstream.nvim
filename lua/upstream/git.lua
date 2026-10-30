-- Async git helpers (cwd = the editor's cwd). Callbacks run on the main loop.

local M = {}

-- run(args, cb(err, stdout)) with a timeout; `git push` gets a longer one
function M.run(args, cb, timeout)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, { text = true, cwd = vim.fn.getcwd(), timeout = timeout or 10000 },
    vim.schedule_wrap(function(res)
      if res.code == 0 then return cb(nil, res.stdout or "") end
      local msg = vim.trim(res.stderr or "")
      if res.code == 124 then msg = "git " .. args[1] .. " timed out" end
      cb(msg ~= "" and msg or ("git exited with code " .. res.code), res.stdout)
    end))
  if not ok then vim.schedule(function() cb(tostring(err)) end) end
end

function M.branch(cb)
  M.run({ "branch", "--show-current" }, function(err, out)
    cb(err, not err and vim.trim(out) ~= "" and vim.trim(out) or nil)
  end)
end

-- The ref to compare against: origin/<base> when it exists (what the PR will
-- actually be diffed against), else the local <base>.
function M.base_ref(base, cb)
  M.run({ "rev-parse", "--verify", "--quiet", "origin/" .. base }, function(err)
    cb(err and base or ("origin/" .. base))
  end)
end

-- upstream_state(cb(has_upstream, ahead))
function M.upstream_state(cb)
  M.run({ "rev-list", "--count", "@{u}..HEAD" }, function(err, out)
    if err then return cb(false, 0) end
    cb(true, tonumber(vim.trim(out)) or 0)
  end)
end

function M.push(branch, cb)
  M.run({ "push", "-u", "origin", branch }, cb, 60000)
end

-- commits(base_ref, cb(err, { {subject, body} })) oldest first
function M.commits(base_ref, cb)
  M.run({ "log", "--reverse", "--format=%s%x1f%b%x1e", base_ref .. "..HEAD" }, function(err, out)
    if err then return cb(err) end
    local list = {}
    for rec in out:gmatch("(.-)\30") do
      local subj, body = rec:match("^%s*(.-)\31(.*)$")
      if subj then list[#list + 1] = { subject = subj, body = vim.trim(body or "") } end
    end
    cb(nil, list)
  end)
end

-- Diff for a prompt: whole files up to `per_file` lines each, all within a
-- `budget` of lines; files past the budget only appear in the --stat.
function M.diff_for_prompt(base_ref, cb, per_file, budget)
  per_file, budget = per_file or 300, budget or 2500
  M.run({ "diff", "--stat", base_ref .. "...HEAD" }, function(err, stat)
    if err then return cb(err) end
    M.run({ "diff", "--no-color", base_ref .. "...HEAD" }, function(err2, diff)
      if err2 then return cb(err2) end
      cb(nil, M.truncate_diff(diff, per_file, budget), stat)
    end)
  end)
end

-- Split a unified diff per file and truncate each to `per_file` lines; stop
-- adding files once `budget` lines are used.
function M.truncate_diff(diff, per_file, budget)
  local files, cur = {}, nil
  for line in (diff .. "\n"):gmatch("(.-)\n") do
    if line:match("^diff %-%-git ") then
      cur = { line }
      files[#files + 1] = cur
    elseif cur then
      cur[#cur + 1] = line
    end
  end
  local out, used, skipped = {}, 0, 0
  for _, f in ipairs(files) do
    if used >= budget then
      skipped = skipped + 1
    else
      local n = math.min(#f, per_file, budget - used)
      vim.list_extend(out, vim.list_slice(f, 1, n))
      if n < #f then out[#out + 1] = ("… (%d more lines of this file truncated)"):format(#f - n) end
      used = used + n
    end
  end
  if skipped > 0 then out[#out + 1] = ("… (%d more files omitted; see the stat)"):format(skipped) end
  return table.concat(out, "\n")
end

return M
