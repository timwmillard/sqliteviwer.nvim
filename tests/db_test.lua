-- Tests for read-only access in lua/sqlite-viewer/db.lua, against real
-- databases made with the sqlite3 CLI. Run from the repo root:
--
--   nvim --headless -u NONE -l tests/db_test.lua
--
-- Exits non-zero if any test fails.

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.rtp:prepend(root)

local db = require("sqlite-viewer.db")
db.setup({ sqlite_cmd = "sqlite3", display_mode = "list" })

local failures = 0
local function check(name, cond, detail)
  if cond then
    io.stdout:write("PASS " .. name .. "\n")
  else
    failures = failures + 1
    io.stdout:write("FAIL " .. name .. (detail and (": " .. detail) or "") .. "\n")
  end
end

local function sh(args)
  local res = vim.system(args, { text = true }):wait()
  assert(res.code == 0, table.concat(args, " ") .. ": " .. (res.stderr or ""))
end

-- A directory whose name needs escaping in a file: URI.
local dir = vim.fn.tempname() .. " dir #1?x"
vim.fn.mkdir(dir, "p")
local function path(name)
  return dir .. "/" .. name
end
local function exists(p)
  return vim.uv.fs_stat(p) ~= nil
end

-- A WAL database left as SQLite leaves one when the last connection
-- closes: no -wal or -shm. (macOS's sqlite3 keeps them, so remove them.)
local function make_wal(name, value)
  local p = path(name)
  sh({ "sqlite3", p, "pragma journal_mode=wal; create table t (v text); insert into t values ('" .. value .. "');" })
  os.remove(p .. "-wal")
  os.remove(p .. "-shm")
  return p
end

-- Reads p through both read-only paths; returns the value or the error.
local function read(p)
  local q = db.query_json(p, "select v from t")
  local r = db.raw(p, "select v from t")
  if not q.ok then
    return nil, q.err
  end
  if not r.ok then
    return nil, r.err
  end
  return q.data[1] and q.data[1].v, r.data[2]
end

-- 1. Closed WAL database: no sidecars.
do
  local p = make_wal("closed.db", "closed ok")
  local v, raw = read(p)
  check("closed WAL database is readable", v == "closed ok" and raw == "closed ok", raw)
  check("reading it creates no sidecar files", not exists(p .. "-wal") and not exists(p .. "-shm"))
end

-- 2. Stale -shm but no -wal: still can't be opened read-only normally.
do
  local p = make_wal("stale_shm.db", "stale shm ok")
  io.open(p .. "-shm", "w"):close()
  local v, raw = read(p)
  check("WAL database with only a stale -shm is readable", v == "stale shm ok", raw)
end

-- 3. Empty -wal: the normal read-only path works.
do
  local p = make_wal("empty_wal.db", "empty wal ok")
  io.open(p .. "-wal", "w"):close()
  local v, raw = read(p)
  check("WAL database with an empty -wal is readable", v == "empty wal ok", raw)
end

-- 4. Rollback-journal database.
do
  local p = path("rollback.db")
  sh({ "sqlite3", p, "create table t (v text); insert into t values ('rollback ok');" })
  local v, raw = read(p)
  check("rollback-journal database is readable", v == "rollback ok", raw)
end

-- 5. WAL database another process has open, mid-transaction: read through
-- the normal path, seeing only committed data.
do
  local p = make_wal("live.db", "committed")
  local writer = vim.system({ "sqlite3", p }, { stdin = true })
  writer:write("begin; insert into t values ('uncommitted'); select 1;\n")
  vim.wait(2000, function()
    return exists(p .. "-wal")
  end)
  local q = db.query_json(p, "select v from t order by rowid")
  local values = q.ok and vim.tbl_map(function(row)
    return row.v
  end, q.data) or {}
  check(
    "open WAL database shows only committed rows",
    q.ok and #values == 1 and values[1] == "committed",
    q.ok and table.concat(values, ",") or q.err
  )
  writer:write("rollback;\n")
  writer:write(nil)
  writer:wait(2000)
end

-- 6. Missing file: an error, as before.
do
  local q = db.query_json(path("missing.db"), "select 1")
  check("missing database is an error", not q.ok and q.err:find("unable to open") ~= nil, q.err)
  check("and isn't created", not exists(path("missing.db")))
end

-- 7. URIs.
do
  check(
    "unix path is escaped",
    db._immutable_uri("/tmp/a b/c#1?x.db") == "file:///tmp/a b/c%231%3Fx.db?immutable=1",
    db._immutable_uri("/tmp/a b/c#1?x.db")
  )
  check(
    "percent is escaped first",
    db._immutable_uri("/tmp/100%.db") == "file:///tmp/100%25.db?immutable=1",
    db._immutable_uri("/tmp/100%.db")
  )
  -- fnamemodify(":p") leaves an absolute Windows path alone on any OS.
  local win = db._immutable_uri([[C:\Users\me\app.db]])
  if vim.fn.has("win32") == 1 then
    check("windows path gets file:///C:/", win == "file:///C:/Users/me/app.db?immutable=1", win)
  else
    check("backslashes become slashes", not win:find("\\", 1, true), win)
  end
end

vim.fn.delete(vim.fn.fnamemodify(dir, ":h"), "rf")
io.stdout:write((failures == 0 and "all passed" or (failures .. " failed")) .. "\n")
os.exit(failures == 0 and 0 or 1)
