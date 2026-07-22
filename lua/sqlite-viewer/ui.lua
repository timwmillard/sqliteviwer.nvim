-- Viewer UI: a narrow table-list pane on the left and a paged results grid
-- on the right (the buffer that BufReadCmd handed us).

local api = vim.api
local db = require("sqlite-viewer.db")
local render = require("sqlite-viewer.render")

local M = {}

local config = {}
local states = {} -- grid bufnr -> viewer state
local warned_missing_binary = false

function M.setup(cfg)
  config = cfg
end

local function notify(msg, level)
  vim.notify("sqlite-viewer: " .. msg, level or vim.log.levels.INFO)
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function map(buf, lhs, fn, desc)
  if lhs and lhs ~= "" then
    vim.keymap.set("n", lhs, fn, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = "sqlite-viewer: " .. desc,
    })
  end
end

local function close_win(win)
  if win and api.nvim_win_is_valid(win) then
    pcall(api.nvim_win_close, win, true)
  end
end

local function delete_buf(buf)
  if buf and api.nvim_buf_is_valid(buf) then
    pcall(api.nvim_buf_delete, buf, { force = true })
  end
end

local function scratch_opts(buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "sqliteviewer"
end

local function render_grid(state)
  local lines
  if not state.current_table then
    lines = { "No tables in database.", "", "Press `" .. (config.keymaps.quit or "q") .. "` to close." }
  else
    local first = state.total_rows == 0 and 0 or state.offset + 1
    local last = math.min(state.offset + #state.rows, state.total_rows)
    lines = {
      string.format("%s — rows %d–%d of %d", state.current_table, first, last, state.total_rows),
      "",
    }
    vim.list_extend(lines, render.grid(state.columns, state.rows, { max_col_width = config.max_col_width }))
    if state.total_rows == 0 then
      lines[#lines + 1] = "(no rows)"
    end
  end
  set_lines(state.grid_buf, lines)
end

local function render_sidebar(state)
  local lines = state.tables
  if #lines == 0 then
    lines = { "(no tables)" }
  end
  set_lines(state.side_buf, lines)
end

local function load_table(state, name, offset)
  local info = db.table_info(state.path, name)
  if not info.ok then
    notify(info.err, vim.log.levels.ERROR)
    return
  end
  local columns = {}
  for _, col in ipairs(info.data) do
    columns[#columns + 1] = col.name
  end

  local count = db.row_count(state.path, name)
  if not count.ok then
    notify(count.err, vim.log.levels.ERROR)
    return
  end
  local total = count.data

  offset = math.max(0, offset or 0)
  if total > 0 then
    local last_page_start = math.floor((total - 1) / config.page_size) * config.page_size
    offset = math.min(offset, last_page_start)
  else
    offset = 0
  end

  local rows = db.rows(state.path, name, columns, config.page_size, offset)
  if not rows.ok then
    notify(rows.err, vim.log.levels.ERROR)
    return
  end

  state.current_table = name
  state.schema = info.data
  state.columns = columns
  state.total_rows = total
  state.offset = offset
  state.rows = rows.data
  render_grid(state)
end

local function page(state, direction)
  if not state.current_table then
    return
  end
  local new_offset = math.max(0, state.offset + direction * config.page_size)
  if new_offset >= state.total_rows and state.total_rows > 0 then
    return
  end
  if new_offset == state.offset then
    return
  end
  load_table(state, state.current_table, new_offset)
end

local function refresh(state)
  local tables = db.list_tables(state.path, config.include_views)
  if not tables.ok then
    notify(tables.err, vim.log.levels.ERROR)
    return
  end
  state.tables = tables.data
  render_sidebar(state)
  if state.current_table and vim.tbl_contains(state.tables, state.current_table) then
    load_table(state, state.current_table, state.offset)
  elseif state.tables[1] then
    load_table(state, state.tables[1], 0)
  else
    state.current_table = nil
    render_grid(state)
  end
end

local function close(state)
  -- Tear the side windows down first: doing it from inside the grid buffer's
  -- BufWipeout autocmd can abort the buffer deletion when one of them is the
  -- current window.
  states[state.grid_buf] = nil
  close_win(state.side_win)
  close_win(state.query_win)
  delete_buf(state.side_buf)
  delete_buf(state.query_buf)
  delete_buf(state.grid_buf)
end

-- Execute the query buffer's contents against the database. Results render
-- into the grid pane; statements that return no rows (writes, DDL) refresh
-- the whole viewer so their effect is visible immediately.
local function run_query(state)
  if not (state.query_buf and api.nvim_buf_is_valid(state.query_buf)) then
    return
  end
  local sql = table.concat(api.nvim_buf_get_lines(state.query_buf, 0, -1, false), "\n")
  if vim.trim(sql) == "" then
    return
  end
  local res = db.exec(state.path, sql)
  if not res.ok then
    set_lines(state.grid_buf, vim.split("SQL error:\n\n" .. (res.err or "unknown error"), "\n"))
    return
  end
  if #res.data == 0 then
    refresh(state)
    notify("statement executed — no rows returned")
    return
  end
  local shown = {}
  for i = 1, math.min(#res.data, config.page_size) do
    shown[i] = res.data[i]
  end
  local title = string.format("query — %d rows", #res.data)
  if #shown < #res.data then
    title = title .. string.format(" (showing first %d)", #shown)
  end
  local lines = { title, "" }
  vim.list_extend(lines, render.grid(res.columns, shown, { max_col_width = config.max_col_width }))
  set_lines(state.grid_buf, lines)
end

-- Open (or focus) the SQL query pane below the grid. The buffer survives the
-- pane being closed, so query text persists while the viewer is open.
local function open_query(state)
  if state.query_win and api.nvim_win_is_valid(state.query_win) then
    api.nvim_set_current_win(state.query_win)
    return
  end
  local grid_win = api.nvim_win_is_valid(state.grid_win) and state.grid_win
    or vim.fn.win_findbuf(state.grid_buf)[1]
  if not grid_win then
    return
  end
  state.grid_win = grid_win
  api.nvim_set_current_win(grid_win)
  vim.cmd("belowright 8split")
  state.query_win = api.nvim_get_current_win()

  if not (state.query_buf and api.nvim_buf_is_valid(state.query_buf)) then
    local buf = api.nvim_create_buf(false, true)
    state.query_buf = buf
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "sql"
    pcall(api.nvim_buf_set_name, buf, "sqlite-viewer://query")
    map(buf, config.keymaps.run_query, function()
      run_query(state)
    end, "run query")
    map(buf, config.keymaps.quit, function()
      if state.query_win and api.nvim_win_is_valid(state.query_win) then
        api.nvim_win_close(state.query_win, true)
      end
    end, "close query pane")
  end
  api.nvim_win_set_buf(state.query_win, state.query_buf)
  vim.wo[state.query_win].winfixheight = true
end

local function show_schema(state)
  if not state.schema or not state.current_table then
    return
  end
  local lines = render.grid(
    { "cid", "name", "type", "notnull", "dflt_value", "pk" },
    state.schema,
    { max_col_width = config.max_col_width }
  )
  table.insert(lines, 1, "")
  table.insert(lines, 1, "Schema: " .. state.current_table)

  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(width, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 4)

  local buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "sqliteviewer"
  local win = api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[win].wrap = false
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
end

-- Build the sidebar window/buffer and wire up keymaps. Runs via vim.schedule
-- so we never split windows from inside the BufReadCmd autocmd.
local function build_windows(state)
  local grid_win = state.grid_win
  if not (api.nvim_win_is_valid(grid_win) and api.nvim_buf_is_valid(state.grid_buf)) then
    return
  end

  api.nvim_set_current_win(grid_win)
  vim.wo[grid_win].wrap = false
  vim.wo[grid_win].cursorline = true

  vim.cmd("leftabove 25vsplit")
  local side_win = api.nvim_get_current_win()
  local side_buf = api.nvim_create_buf(false, true)
  api.nvim_win_set_buf(side_win, side_buf)
  scratch_opts(side_buf)
  pcall(api.nvim_buf_set_name, side_buf, "sqlite-viewer://tables")
  state.side_win = side_win
  state.side_buf = side_buf

  vim.wo[side_win].number = false
  vim.wo[side_win].relativenumber = false
  vim.wo[side_win].signcolumn = "no"
  vim.wo[side_win].winfixwidth = true
  vim.wo[side_win].cursorline = true
  vim.wo[side_win].wrap = false

  local keys = config.keymaps

  map(side_buf, keys.open_table, function()
    local row = api.nvim_win_get_cursor(side_win)[1]
    local name = state.tables[row]
    if name then
      load_table(state, name, 0)
    end
  end, "open table under cursor")

  for _, buf in ipairs({ side_buf, state.grid_buf }) do
    map(buf, keys.refresh, function()
      refresh(state)
    end, "refresh")
    map(buf, keys.schema, function()
      show_schema(state)
    end, "show schema")
    map(buf, keys.quit, function()
      close(state)
    end, "close viewer")
    map(buf, keys.query, function()
      open_query(state)
    end, "open SQL query pane")
  end

  map(state.grid_buf, keys.next_page, function()
    page(state, 1)
  end, "next page")
  map(state.grid_buf, keys.prev_page, function()
    page(state, -1)
  end, "previous page")

  api.nvim_create_autocmd("BufWipeout", {
    buffer = state.grid_buf,
    once = true,
    callback = function()
      states[state.grid_buf] = nil
      close_win(state.side_win)
      close_win(state.query_win)
      delete_buf(state.side_buf)
      delete_buf(state.query_buf)
    end,
  })

  render_sidebar(state)
  if state.tables[1] then
    load_table(state, state.tables[1], 0)
  else
    render_grid(state)
  end

  -- start with the cursor on the table list
  api.nvim_set_current_win(side_win)
  api.nvim_win_set_cursor(side_win, { 1, 0 })
end

--- Take over `grid_buf` (the buffer BufReadCmd gave us) as a viewer for `path`.
---@param path string
---@param grid_buf integer
function M.open(path, grid_buf)
  local existing = states[grid_buf]
  if existing then
    -- :edit on an already-open viewer -> just refresh it
    refresh(existing)
    return
  end

  if not db.check_binary() then
    if not warned_missing_binary then
      warned_missing_binary = true
      notify(
        ("`%s` not found in PATH — install sqlite3 or set `sqlite_cmd`"):format(config.sqlite_cmd),
        vim.log.levels.ERROR
      )
    end
    scratch_opts(grid_buf)
    set_lines(grid_buf, { "sqlite-viewer: `" .. config.sqlite_cmd .. "` not found in PATH." })
    return
  end

  local tables = db.list_tables(path, config.include_views)
  if not tables.ok then
    notify("failed to read " .. path .. ": " .. (tables.err or "unknown error"), vim.log.levels.ERROR)
    scratch_opts(grid_buf)
    set_lines(grid_buf, { "sqlite-viewer: failed to read database.", "", tables.err or "" })
    return
  end

  scratch_opts(grid_buf)
  set_lines(grid_buf, { "Loading " .. path .. " …" })

  local state = {
    path = path,
    grid_buf = grid_buf,
    grid_win = api.nvim_get_current_win(),
    tables = tables.data,
    current_table = nil,
    columns = {},
    rows = {},
    offset = 0,
    total_rows = 0,
    schema = nil,
  }
  states[grid_buf] = state

  vim.schedule(function()
    if states[grid_buf] == state then
      build_windows(state)
    end
  end)
end

-- Exposed for testing.
function M._get_state(grid_buf)
  return states[grid_buf]
end

return M
