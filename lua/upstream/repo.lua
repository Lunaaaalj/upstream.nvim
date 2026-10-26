-- Repo detection for the cwd: `gh repo view`, cached per cwd. Failures are
-- classified (no gh / not authenticated / not a GitHub repo) so the user gets
-- one clear message instead of raw gh stderr.

local gh = require("upstream.gh")

local M = {}

local by_cwd = {}

local function classify(err)
  if vim.fn.executable("gh") == 0 then
    return "the GitHub CLI (`gh`) is not installed"
  end
  local e = (err or ""):lower()
  if e:find("auth login") or e:find("not logged") or e:find("authentication") then
    return "`gh` is not authenticated; run `gh auth login`"
  end
  if e:find("not a git repository") or e:find("no git remotes") or e:find("none of the git remotes") then
    return "the current directory is not a GitHub repository"
  end
  return err or "could not detect the repository"
end

-- detect(cb, force): cb(err, repo) with repo = { owner, name, full, url,
-- default_branch, branch }. `branch` is re-read every call (it changes).
function M.detect(cb, force)
  local cwd = vim.fn.getcwd()
  local function finish(r)
    vim.system({ "git", "branch", "--show-current" }, { text = true, cwd = cwd, timeout = 3000 },
      vim.schedule_wrap(function(res)
        local b = res.code == 0 and vim.trim(res.stdout or "") or ""
        r.branch = b ~= "" and b or nil
        cb(nil, r)
      end))
  end
  if by_cwd[cwd] and not force then return finish(by_cwd[cwd]) end
  gh.json({ "repo", "view", "--json", "nameWithOwner,defaultBranchRef,url" }, function(err, data)
    if err or type(data) ~= "table" or not data.nameWithOwner then return cb(classify(err)) end
    local owner, name = data.nameWithOwner:match("^([^/]+)/(.+)$")
    local r = {
      owner = owner,
      name = name,
      full = data.nameWithOwner,
      url = data.url,
      default_branch = vim.tbl_get(data, "defaultBranchRef", "name") or "main",
    }
    by_cwd[cwd] = r
    finish(r)
  end, { cwd = cwd })
end

return M
