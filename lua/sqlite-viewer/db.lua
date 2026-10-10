-- All sqlite3 CLI calls. Display queries run in the configured output mode
-- (default `box`) and their stdout is shown verbatim; metadata queries (table
-- names, row counts, column names) use `-json` so results can be decoded with
-- vim.json.decode. Every function returns a structured result:
-- { ok = true, data = ... } or { ok = false, err = "..." }.

local M = {}

local config = { sqlite_cmd = "sqlite3", display_mode = "box" }
local binary_ok -- cached result of check_binary

function M.setup(cfg)
  config = cfg
  binary_ok = nil
end

--- Quote a SQL identifier (table/column name) for safe interpolation.
---@param name string
---@return string
function M.quote_ident(name)
  return '"' .. tostring(name):gsub('"', '""') .. '"'
end

-- Run the sqlite3 binary with an argv array (no shell string building).
local function run(args)
  local cmd = { config.sqlite_cmd }
  vim.list_extend(cmd, args)
  if vim.system then
    local ok, proc = pcall(vim.system, cmd, { text = true })
    if not ok then
      return { ok = false, err = tostring(proc) }
    end
    local res = proc:wait()
    if res.code ~= 0 then
      local err = vim.trim(res.stderr or "")
      return { ok = false, err = err ~= "" and err or ("sqlite3 exited with code " .. res.code) }
    end
    return { ok = true, stdout = res.stdout or "" }
  end
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return { ok = false, err = vim.trim(out) }
  end
  return { ok = true, stdout = out }
end

local uv = vim.uv or vim.loop

-- Whether path is a WAL-mode database with no -wal file. sqlite3
-- -readonly can't open one: a read-only connection may create the -shm but
-- not the -wal. It also means nothing has the database open, since every
-- connection in WAL mode keeps a -wal, and that closing the last one
-- checkpointed everything into the main file and removed the -wal. So the
-- main file can be read as immutable: without locks or sidecar files, and
-- without creating any.
local function unopened_wal(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local header = f:read(20)
  f:close()
  -- Bytes 18 and 19 (1-based 19 and 20) are 2 in WAL mode.
  if not header or #header < 20 or header:sub(1, 15) ~= "SQLite format 3" or header:byte(19) ~= 2 then
    return false
  end
  return uv.fs_stat(path .. "-wal") == nil
end

-- A file: URI opening path as immutable. Characters URIs treat specially
-- are escaped; Windows paths get forward slashes and a leading slash
-- (file:///C:/...).
local function immutable_uri(path)
  local abs = vim.fn.fnamemodify(path, ":p"):gsub("\\", "/")
  if abs:sub(1, 1) ~= "/" then
    abs = "/" .. abs
  end
  local enc = abs:gsub("%%", "%%25"):gsub("%?", "%%3F"):gsub("#", "%%23")
  return "file://" .. enc .. "?immutable=1"
end

-- Run a read-only sqlite3 call: flags, then the database, then sql. A WAL
-- database with no -wal (see unopened_wal) is read as immutable, since
-- sqlite3 -readonly can't open it.
local function run_readonly(flags, path, sql)
  local target = unopened_wal(path) and immutable_uri(path) or path
  return run(vim.list_extend(vim.deepcopy(flags), { target, sql }))
end

-- Exposed for tests only.
M._immutable_uri = immutable_uri

-- JSON metadata query (read-only). Used where the plugin needs values, not
-- display text: table names, row counts, column metadata.
local function query(path, sql)
  local res = run_readonly({ "-readonly", "-json" }, path, sql)
  if not res.ok then
    return res
  end
  local out = vim.trim(res.stdout)
  if out == "" then
    return { ok = true, data = {} }
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return { ok = false, err = "could not parse sqlite3 JSON output: " .. tostring(decoded) }
  end
  return { ok = true, data = decoded }
end

--- Run SQL and return sqlite3's own formatted output as a list of lines,
--- untouched apart from splitting on newlines. `opts.readonly = false` drops
--- the -readonly flag (the query pane's write path).
---@param path string
---@param sql string
---@param opts { readonly: boolean }|nil
function M.raw(path, sql, opts)
  opts = opts or {}
  -- box/table/markdown imply headers, but plain modes (column, list, …) don't
  local flags = { "-header", "-" .. (config.display_mode or "box") }
  local res
  if opts.readonly ~= false then
    table.insert(flags, 1, "-readonly")
    res = run_readonly(flags, path, sql)
  else
    res = run(vim.list_extend(flags, { path, sql }))
  end
  if not res.ok then
    return res
  end
  local lines = vim.split(res.stdout, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    table.remove(lines)
  end
  return { ok = true, data = lines }
end

--- Whether the configured sqlite3 binary is callable.
---@return boolean
function M.check_binary()
  if binary_ok == nil then
    binary_ok = vim.fn.executable(config.sqlite_cmd) == 1
  end
  return binary_ok
end

--- List table (and optionally view) names.
---@param path string
---@param include_views boolean|nil
---@return table result list of names in data
function M.list_tables(path, include_views)
  local types = include_views and "('table','view')" or "('table')"
  local res = query(
    path,
    "SELECT name FROM sqlite_master WHERE type IN "
      .. types
      .. " AND name NOT LIKE 'sqlite_%' ORDER BY name;"
  )
  if not res.ok then
    return res
  end
  local names = {}
  for _, row in ipairs(res.data) do
    names[#names + 1] = row.name
  end
  return { ok = true, data = names }
end

--- Column metadata for a table, in schema order.
--- Each entry: { cid, name, type, notnull, dflt_value, pk }.
---@param path string
---@param table_name string
function M.table_info(path, table_name)
  return query(path, "PRAGMA table_info(" .. M.quote_ident(table_name) .. ");")
end

--- Total row count of a table.
---@param path string
---@param table_name string
function M.row_count(path, table_name)
  local res = query(path, "SELECT count(*) AS n FROM " .. M.quote_ident(table_name) .. ";")
  if not res.ok then
    return res
  end
  return { ok = true, data = res.data[1] and res.data[1].n or 0 }
end

--- Quote a SQL string literal for safe interpolation into a query.
---@param value string
---@return string
function M.quote_value(value)
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

--- Foreign key metadata for a table (PRAGMA foreign_key_list). Each entry:
--- { id, seq, table, from, to, on_update, on_delete, match }. `to` is nil
--- when the reference relies on the referenced table's primary key.
---@param path string
---@param table_name string
function M.foreign_key_list(path, table_name)
  return query(path, "PRAGMA foreign_key_list(" .. M.quote_ident(table_name) .. ");")
end

--- Name of `table_name`'s single-column primary key, or nil if it has none
--- or a composite one.
---@param path string
---@param table_name string
function M.primary_key_column(path, table_name)
  local info = M.table_info(path, table_name)
  if not info.ok then
    return info
  end
  local pk_col
  for _, col in ipairs(info.data) do
    if col.pk and col.pk > 0 then
      if pk_col then
        return { ok = true, data = nil } -- composite key, not supported
      end
      pk_col = col.name
    end
  end
  return { ok = true, data = pk_col }
end

--- Every foreign key in the database, one query via the pragma_foreign_key_list
--- table-valued function rather than one PRAGMA per table. Each entry:
--- { from_table, to_table, from_col, to_col }. `to_col` is nil when the
--- reference relies on the referenced table's primary key.
---@param path string
function M.all_foreign_keys(path)
  return query(
    path,
    'SELECT m.name AS from_table, fk."table" AS to_table, fk."from" AS from_col, fk."to" AS to_col '
      .. "FROM sqlite_master m, pragma_foreign_key_list(m.name) fk WHERE m.type = 'table';"
  )
end

--- Tables (and the column) that hold a foreign key pointing at
--- `table_name`.`column_name` — the reverse of foreign_key_list. Each entry:
--- { table, column }.
---@param path string
---@param table_name string
---@param column_name string
function M.child_tables(path, table_name, column_name)
  local all = M.all_foreign_keys(path)
  if not all.ok then
    return all
  end
  local pk -- resolved lazily; false once looked up with no result, to avoid re-querying
  local matches = {}
  local seen = {}
  for _, fk in ipairs(all.data) do
    if fk.to_table == table_name then
      local to_col = fk.to_col
      if not to_col or to_col == "" then
        if pk == nil then
          local pk_res = M.primary_key_column(path, table_name)
          pk = (pk_res.ok and pk_res.data) or false
        end
        to_col = pk or nil
      end
      if to_col == column_name then
        local key = fk.from_table .. "." .. fk.from_col
        if not seen[key] then
          seen[key] = true
          matches[#matches + 1] = { table = fk.from_table, column = fk.from_col }
        end
      end
    end
  end
  return { ok = true, data = matches }
end

--- 0-based position of the row where `column` = `value`, in the table's
--- natural rowid order — the same order `rows()` relies on for paging.
--- `data` is nil when no row matches.
---@param path string
---@param table_name string
---@param column string
---@param value string
function M.find_row_offset(path, table_name, column, value)
  local t = M.quote_ident(table_name)
  local c = M.quote_ident(column)
  local v = M.quote_value(value)
  local rowid_res = query(path, "SELECT rowid AS r FROM " .. t .. " WHERE " .. c .. " = " .. v .. " LIMIT 1;")
  if not rowid_res.ok then
    return rowid_res
  end
  local row = rowid_res.data[1]
  if not row then
    return { ok = true, data = nil }
  end
  local count_res = query(path, "SELECT count(*) AS n FROM " .. t .. " WHERE rowid < " .. tostring(row.r) .. ";")
  if not count_res.ok then
    return count_res
  end
  return { ok = true, data = count_res.data[1] and count_res.data[1].n or 0 }
end

-- BLOB cells summarized as '<BLOB n bytes>' so raw bytes never land in the
-- buffer (or get scanned for embedded newlines — see rows_json below).
local function blob_safe_select_list(columns)
  if not (columns and #columns > 0) then
    return "*"
  end
  local parts = {}
  for _, col in ipairs(columns) do
    local q = M.quote_ident(col)
    parts[#parts + 1] = string.format(
      "CASE WHEN typeof(%s) = 'blob' THEN '<BLOB ' || length(%s) || ' bytes>' ELSE %s END AS %s",
      q,
      q,
      q,
      q
    )
  end
  return table.concat(parts, ", ")
end

--- Fetch a page of rows as raw display lines. When `columns` is given (from
--- table_info), BLOB cells are summarized in SQL as '<BLOB n bytes>' so raw
--- bytes never land in the buffer.
---@param path string
---@param table_name string
---@param columns string[]|nil ordered column names
---@param limit integer
---@param offset integer
function M.rows(path, table_name, columns, limit, offset)
  local sql = string.format(
    "SELECT %s FROM %s LIMIT %d OFFSET %d;",
    blob_safe_select_list(columns),
    M.quote_ident(table_name),
    math.floor(limit),
    math.floor(offset)
  )
  return M.raw(path, sql)
end

--- The same page as `rows`, but as decoded rows (array of column -> value)
--- instead of display text. A cell containing embedded newlines makes
--- sqlite3 print that row across multiple physical lines (and, in box/table
--- mode, adds a border between every row on the page once any row does
--- this) — this is how the UI works out exactly how many physical lines
--- each row occupies, so cursor/row mapping stays correct.
---@param path string
---@param table_name string
---@param columns string[]|nil ordered column names
---@param limit integer
---@param offset integer
function M.rows_json(path, table_name, columns, limit, offset)
  local sql = string.format(
    "SELECT %s FROM %s LIMIT %d OFFSET %d;",
    blob_safe_select_list(columns),
    M.quote_ident(table_name),
    math.floor(limit),
    math.floor(offset)
  )
  return query(path, sql)
end

--- Run arbitrary SQL read-only and return decoded JSON rows. Exposes the
--- module's JSON query path for callers (the query pane) that need
--- structured data alongside `raw`'s formatted text for the same statement.
---@param path string
---@param sql string
function M.query_json(path, sql)
  return query(path, sql)
end

return M
