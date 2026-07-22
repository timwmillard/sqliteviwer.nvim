-- All sqlite3 CLI calls. Queries run with `sqlite3 -readonly -json` and are
-- parsed with vim.json.decode. Every function returns a structured result:
-- { ok = true, data = ... } or { ok = false, err = "..." }.

local M = {}

local config = { sqlite_cmd = "sqlite3" }
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

local function query(path, sql)
  local res = run({ "-readonly", "-json", path, sql })
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

-- Decoded JSON objects lose key order; recover the SELECT's column order by
-- scanning the first row's raw JSON text. Falls back to sorted names when the
-- scan is ambiguous (e.g. braces or quote-colon sequences inside cell values).
local function column_order(json_text, first_row)
  local sorted = {}
  for k in pairs(first_row or {}) do
    sorted[#sorted + 1] = k
  end
  table.sort(sorted)
  local obj = json_text:match("%b{}")
  if not obj then
    return sorted
  end
  local keys, seen = {}, {}
  for k in obj:gmatch('"([^"]-)"%s*:') do
    if seen[k] or first_row[k] == nil then
      return sorted
    end
    seen[k] = true
    keys[#keys + 1] = k
  end
  if #keys ~= #sorted then
    return sorted
  end
  return keys
end

--- Execute arbitrary SQL read-write (no -readonly flag). Returns decoded rows
--- plus their column order; writes and DDL return ok with empty data.
---@param path string
---@param sql string
function M.exec(path, sql)
  local res = run({ "-json", path, sql })
  if not res.ok then
    return res
  end
  local out = vim.trim(res.stdout)
  if out == "" then
    return { ok = true, data = {}, columns = {} }
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    if out:find("]%s*\n%s*%[") then
      return { ok = false, err = "multiple result-returning statements are not supported — run one SELECT at a time" }
    end
    return { ok = false, err = "could not parse sqlite3 JSON output: " .. tostring(decoded) }
  end
  return { ok = true, data = decoded, columns = column_order(out, decoded[1]) }
end

--- Fetch a page of rows. When `columns` is given (from table_info), BLOB cells
--- are summarized in SQL as '<BLOB n bytes>' so the JSON output stays valid —
--- the CLI's json mode cannot represent raw blob bytes safely.
---@param path string
---@param table_name string
---@param columns string[]|nil ordered column names
---@param limit integer
---@param offset integer
function M.rows(path, table_name, columns, limit, offset)
  local select_list = "*"
  if columns and #columns > 0 then
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
    select_list = table.concat(parts, ", ")
  end
  local sql = string.format(
    "SELECT %s FROM %s LIMIT %d OFFSET %d;",
    select_list,
    M.quote_ident(table_name),
    math.floor(limit),
    math.floor(offset)
  )
  return query(path, sql)
end

return M
