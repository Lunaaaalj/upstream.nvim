-- Async `gh` runner. Every call has a timeout, callbacks run on the main loop,
-- and each distinct error is reported once (a failing refresh loop would
-- otherwise notify on every redraw).

local config = require("upstream.config")

local M = {}

local last_err

function M.notify_once(msg, level)
  if msg == last_err then return end
  last_err = msg
  vim.notify("upstream: " .. msg, level or vim.log.levels.WARN)
end

-- run({ "repo", "view", ... }, function(err, stdout) end, { timeout = ms })
function M.run(args, cb, opts)
  opts = opts or {}
  local cmd = { "gh" }
  vim.list_extend(cmd, args)
  local ok, err = pcall(vim.system, cmd, {
    text = true,
    timeout = opts.timeout or config.options.timeout,
    cwd = opts.cwd,
    env = { GH_PROMPT_DISABLED = "1", NO_COLOR = "1" },
  }, vim.schedule_wrap(function(res)
    if res.code == 0 then return cb(nil, res.stdout or "") end
    local msg = vim.trim(res.stderr or "")
    -- vim.system kills a timed-out process with SIGTERM (code 124)
    if res.code == 124 or (res.signal and res.signal ~= 0) then msg = "gh did not answer (timed out)" end
    cb(msg ~= "" and msg or ("gh exited with code " .. res.code), res.stdout)
  end))
  -- `gh` missing from PATH: vim.system throws synchronously
  if not ok then vim.schedule(function() cb(tostring(err), nil) end) end
end

-- Decode JSON stdout; cb(err, decoded).
function M.json(args, cb, opts)
  M.run(args, function(err, out)
    if err then return cb(err) end
    local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
    if not ok then return cb("could not decode gh output") end
    cb(nil, data)
  end, opts)
end

-- graphql(query, { owner = "o", n = 50 }, function(err, data) end)
-- Strings go through -f (raw) so values like "123" stay strings; numbers and
-- booleans go through -F so GraphQL gets typed values. nil vars are omitted,
-- which GraphQL treats as null (handy for `after: $cursor`).
function M.graphql(query, vars, cb, opts)
  local args = { "api", "graphql", "-f", "query=" .. query }
  for k, v in pairs(vars or {}) do
    if type(v) == "table" then
      -- lists use gh's `key[]=value` syntax, one flag per element
      for _, x in ipairs(v) do vim.list_extend(args, { "-f", k .. "[]=" .. tostring(x) }) end
    elseif type(v) == "string" then
      vim.list_extend(args, { "-f", k .. "=" .. v })
    else
      vim.list_extend(args, { "-F", k .. "=" .. tostring(v) })
    end
  end
  M.run(args, function(err, stdout)
    -- `gh api` exits non-zero on GraphQL errors but still prints the JSON
    -- body on stdout, whose message beats gh's generic stderr
    local ok, out = pcall(vim.json.decode, stdout or "", { luanil = { object = true, array = true } })
    if ok and type(out) == "table" and out.errors and out.errors[1] then
      return cb(out.errors[1].message or "GraphQL error")
    end
    if err then return cb(err) end
    if not ok or type(out) ~= "table" then return cb("could not decode GraphQL response") end
    cb(nil, out.data)
  end, opts)
end

return M
