-- Actions: a run's log in a buffer, re-run, cancel. All through `gh run`.
--
-- `gh run view --log` prints "job<TAB>step<TAB>timestamp message" per line;
-- the buffer regroups that under one heading per job › step and drops the
-- timestamps, so ]] / [[ walk the steps. Failed runs show only the failed
-- steps' logs (--log-failed) unless you ask for everything (`a`).

local data = require("upstream.data")
local gh = require("upstream.gh")
local hl = require("upstream.ui.hl")

local M = {}

local ns = vim.api.nvim_create_namespace("upstream_log")

local function failed(it) return it.conclusion == "failure" or it.conclusion == "timed_out" end

-- raw `gh run view --log` → lines, headings (rows), marks { row, hl }
function M.format(raw)
  local lines, heads, marks = {}, {}, {}
  local cur
  for line in ((raw or ""):gsub("\r", "") .. "\n"):gmatch("(.-)\n") do
    local job, step, rest = line:match("^([^\t]*)\t([^\t]*)\t(.*)$")
    if job then
      local key = job .. "\0" .. step
      if key ~= cur then
        cur = key
        if #lines > 0 then lines[#lines + 1] = "" end
        lines[#lines + 1] = ("── %s › %s"):format(job, step)
        heads[#heads + 1] = #lines
        marks[#marks + 1] = { #lines, "UpstreamTitle" }
      end
      -- strip the ISO timestamp (and the UTF-8 BOM gh sometimes leaves)
      local msg = rest:gsub("^\239\187\191", ""):gsub("^%d%d%d%d%-%d%d%-%d%dT[%d:%.]+Z ?", "")
      lines[#lines + 1] = msg
      if msg:find("##[error]", 1, true) or msg:match("^Error") then
        marks[#marks + 1] = { #lines, "UpstreamClosed" }
      elseif msg:find("##[warning]", 1, true) then
        marks[#marks + 1] = { #lines, "UpstreamPending" }
      elseif msg:find("##[group]", 1, true) or msg:find("##[endgroup]", 1, true) then
        marks[#marks + 1] = { #lines, "UpstreamMuted" }
      end
    elseif line ~= "" then
      lines[#lines + 1] = line
    end
  end
  return lines, heads, marks
end

-- logs(repo, it, { all = true }) — opens a tab with the run's log
function M.logs(repo, it, o)
  o = o or {}
  local ui = require("upstream.ui")
  if ui.is_open() then ui.close() end
  local only_failed = failed(it) and not o.all
  vim.cmd.tabnew()
  local buf = vim.api.nvim_get_current_buf()
  pcall(vim.api.nvim_buf_set_name, buf, ("upstream://%s/run/%d/log%s"):format(repo.full, it.number, only_failed and "-failed" or ""))
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "upstream_log"
  vim.wo.wrap = false
  vim.wo.number = false
  vim.wo.relativenumber = false
  hl.setup()
  local title = ("%s · %s%s"):format(it.workflow or "run", it.title or "", only_failed and " (failed steps)" or "")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { title, "loading the log…" })
  vim.bo[buf].modifiable = false

  local heads = {}
  local function jump(step)
    local row = vim.api.nvim_win_get_cursor(0)[1]
    if step > 0 then
      for _, h in ipairs(heads) do if h > row then return vim.api.nvim_win_set_cursor(0, { h, 0 }) end end
    else
      for i = #heads, 1, -1 do if heads[i] < row then return vim.api.nvim_win_set_cursor(0, { heads[i], 0 }) end end
    end
  end
  local mo = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "]]", function() jump(1) end, mo)
  vim.keymap.set("n", "[[", function() jump(-1) end, mo)
  vim.keymap.set("n", "q", function()
    if #vim.api.nvim_list_tabpages() > 1 then vim.cmd.tabclose() else vim.cmd.bdelete() end
  end, mo)
  vim.keymap.set("n", "gx", function() if it.url then vim.ui.open(it.url) end end, mo)
  vim.keymap.set("n", "a", function() M.logs(repo, it, { all = true }) end, mo)
  vim.keymap.set("n", "R", function() M.rerun(repo, it) end, mo)

  local args = { "run", "view", tostring(it.number), "-R", repo.full, only_failed and "--log-failed" or "--log" }
  gh.run(args, function(err, out)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local lines, marks
    if err then
      lines, marks = { title, "", err }, { { 3, "UpstreamClosed" } }
    else
      local body
      body, heads, marks = M.format(out)
      lines = { title, ("]] / [[ steps · a full log · R re-run · gx web · q close"), "" }
      vim.list_extend(lines, #body > 0 and body or { "(empty log; the run may still be in progress)" })
      for i = 1, #heads do heads[i] = heads[i] + 3 end
      for _, m in ipairs(marks) do m[1] = m[1] + 3 end
      table.insert(marks, { 2, "UpstreamMuted" })
    end
    table.insert(marks, { 1, "UpstreamTitle" })
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    for _, m in ipairs(marks) do
      vim.api.nvim_buf_set_extmark(buf, ns, m[1] - 1, 0, { line_hl_group = m[2] })
    end
    -- land on the first error
    for _, m in ipairs(marks) do
      if m[2] == "UpstreamClosed" and m[1] > 3 then
        pcall(vim.api.nvim_win_set_cursor, 0, { m[1], 0 })
        break
      end
    end
  end, { timeout = 60000 })
end

local function after(repo, it)
  -- the run's status changes over the next seconds; refetch its detail
  vim.defer_fn(function() data.detail(repo, "run", it.number, function() end, true) end, 1500)
  data.touch(repo, "actions")
end

function M.rerun(repo, it)
  if it.status ~= "completed" then return vim.notify("upstream: the run is still going", vim.log.levels.WARN) end
  local choices = failed(it) and "&Failed jobs\n&All jobs\n&Cancel" or "&All jobs\n&Cancel"
  local c = vim.fn.confirm(("Re-run %s · %s?"):format(it.workflow or "run", it.title or ""), choices, 1, "Question")
  local args = { "run", "rerun", tostring(it.number), "-R", repo.full }
  if failed(it) then
    if c == 1 then table.insert(args, "--failed") elseif c ~= 2 then return end
  elseif c ~= 1 then
    return
  end
  gh.run(args, function(err)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    vim.notify("upstream: re-run requested", vim.log.levels.INFO)
    after(repo, it)
  end)
end

function M.cancel(repo, it)
  if it.status == "completed" then return vim.notify("upstream: the run already finished", vim.log.levels.INFO) end
  if vim.fn.confirm(("Cancel %s · %s?"):format(it.workflow or "run", it.title or ""), "&Yes\n&No", 2, "Question") ~= 1 then
    return
  end
  gh.run({ "run", "cancel", tostring(it.number), "-R", repo.full }, function(err)
    if err then return vim.notify("upstream: " .. err, vim.log.levels.ERROR) end
    vim.notify("upstream: run cancelled", vim.log.levels.INFO)
    after(repo, it)
  end)
end

return M
