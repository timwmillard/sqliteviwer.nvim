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

-- JSON metadata query (read-only). Used where the plugin needs values, not
-- display text: table names, row counts, column metadata.
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

--- Run SQL and return sqlite3's own formatted output as a list of lines,
--- untouched apart from splitting on newlines. `opts.readonly = false` drops
--- the -readonly flag (the query pane's write path).
---@param path string
---@param sql string
---@param opts { readonly: boolean }|nil
function M.raw(path, sql, opts)
  opts = opts or {}
  local args = {}
  if opts.readonly ~= false then
    args[#args + 1] = "-readonly"
  end
  -- box/table/markdown imply headers, but plain modes (column, list, …) don't
  args[#args + 1] = "-header"
  args[#args + 1] = "-" .. (config.display_mode or "box")
  args[#args + 1] = path
  args[#args + 1] = sql
  local res = run(args)
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

--- Fetch a page of rows as raw display lines. When `columns` is given (from
--- table_info), BLOB cells are summarized in SQL as '<BLOB n bytes>' so raw
--- bytes never land in the buffer.
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
  return M.raw(path, sql)
end

return M
