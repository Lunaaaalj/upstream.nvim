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
    stdin = opts.stdin,
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
-- The request goes as a JSON body on stdin (`--input -`), so variables keep
-- their JSON types: strings stay strings, `{}` is an empty list (clearing all
-- labels needs `labelIds: []`, which `-f key[]=` cannot express), and nil
-- vars are simply absent, which GraphQL treats as null.
function M.graphql(query, vars, cb, opts)
  local body = vim.json.encode({ query = query, variables = vim.tbl_isempty(vars or {}) and vim.empty_dict() or vars })
  opts = vim.tbl_extend("force", opts or {}, { stdin = body })
  M.run({ "api", "graphql", "--method", "POST", "--input", "-" }, function(err, stdout)
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
