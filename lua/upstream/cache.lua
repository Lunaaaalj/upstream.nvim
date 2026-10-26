-- JSON file cache: stdpath("cache")/upstream/<owner>/<repo>/<key>.json.
-- Reads are synchronous (small files, needed for the instant first draw);
-- writes go through libuv so they never block the UI.

local M = {}

local root = vim.fn.stdpath("cache") .. "/upstream"

local function path(repo, key)
  return ("%s/%s/%s/%s.json"):format(root, repo.owner, repo.name, key)
end

function M.read(repo, key)
  local p = path(repo, key)
  local fd = vim.uv.fs_open(p, "r", 438)
  if not fd then return nil end
  local stat = vim.uv.fs_fstat(fd)
  local raw = stat and vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  if not raw then return nil end
  local ok, data = pcall(vim.json.decode, raw, { luanil = { object = true, array = true } })
  return ok and type(data) == "table" and data or nil
end

function M.write(repo, key, data)
  local p = path(repo, key)
  vim.fn.mkdir(vim.fs.dirname(p), "p")
  local ok, raw = pcall(vim.json.encode, data)
  if not ok then return end
  vim.uv.fs_open(p, "w", 420, function(err, fd)
    if err or not fd then return end
    vim.uv.fs_write(fd, raw, 0, function() vim.uv.fs_close(fd) end)
  end)
end

return M
