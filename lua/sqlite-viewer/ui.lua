-- Viewer UI: the buffer BufReadCmd hands us *is* the table view, showing
-- sqlite3's own formatted output. A floating popup (default `L`) lists the
-- tables; `<CR>` there switches the view.

local api = vim.api
local db = require("sqlite-viewer.db")

local M = {}

local config = {}
local states = {} -- viewer bufnr -> state
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

-- Open a centered floating scratch window showing `lines`. Returns buf, win.
local function open_float(lines, title)
  local width = 1
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(math.max(width + 2, 20), vim.o.columns - 4)
  local height = math.min(math.max(#lines, 1), vim.o.lines - 4)

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
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.wo[win].wrap = false
  return buf, win
end

local function render_view(state)
  local lines
  if not state.current_table then
    if #state.tables == 0 then
      lines = {
        "No tables in database.",
        "",
        "Press `" .. (config.keymaps.quit or "q") .. "` to close.",
      }
    else
      lines = {
        "Select a table to view.",
        "",
        "Press `" .. (config.keymaps.table_list or "L") .. "` to list tables.",
      }
    end
  else
    local first = state.total_rows == 0 and 0 or state.offset + 1
    local last = math.min(state.offset + config.page_size, state.total_rows)
    lines = {
      string.format("%s — rows %d–%d of %d", state.current_table, first, last, state.total_rows),
      "",
    }
    vim.list_extend(lines, state.view_lines)
    if state.total_rows == 0 then
      lines[#lines + 1] = "(no rows)"
    end
  end
  set_lines(state.buf, lines)
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
  state.total_rows = total
  state.offset = offset
  state.view_lines = rows.data
  state.columns = columns
  state.view_mode = "table"
  render_view(state)
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
  if state.current_table and vim.tbl_contains(state.tables, state.current_table) then
    load_table(state, state.current_table, state.offset)
  elseif state.tables[1] then
    load_table(state, state.tables[1], 0)
  else
    state.current_table = nil
    render_view(state)
  end
end

local function close(state)
  states[state.buf] = nil
  close_win(state.list_win)
  close_win(state.query_win)
  delete_buf(state.list_buf)
  delete_buf(state.query_buf)
  delete_buf(state.buf)
end

-- Floating table list. Pressing the shortcut again (or q/<Esc>, or leaving
-- the window) closes it; <CR> opens the table under the cursor.
local function open_table_list(state)
  if state.list_win and api.nvim_win_is_valid(state.list_win) then
    api.nvim_win_close(state.list_win, true)
    return
  end
  local names = state.tables
  local lines = #names > 0 and names or { "(no tables)" }
  local buf, win = open_float(lines, "Tables")
  state.list_buf, state.list_win = buf, win
  vim.wo[win].cursorline = true

  for i, name in ipairs(names) do
    if name == state.current_table then
      api.nvim_win_set_cursor(win, { i, 0 })
      break
    end
  end

  local function close_list()
    if api.nvim_win_is_valid(win) then
      pcall(api.nvim_win_close, win, true)
    end
  end

  map(buf, config.keymaps.open_table, function()
    local name = names[api.nvim_win_get_cursor(win)[1]]
    close_list()
    if name then
      load_table(state, name, 0)
    end
  end, "open table under cursor")
  for _, lhs in ipairs({ config.keymaps.table_list, config.keymaps.quit, "<Esc>" }) do
    map(buf, lhs, close_list, "close table list")
  end

  api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(close_list)
    end,
  })
end

-- Execute the query buffer's contents against the database. Raw sqlite3
-- output renders into the main view; statements that return no rows (writes,
-- DDL) refresh the viewer so their effect is visible immediately.
local function run_query(state)
  if not (state.query_buf and api.nvim_buf_is_valid(state.query_buf)) then
    return
  end
  local sql = table.concat(api.nvim_buf_get_lines(state.query_buf, 0, -1, false), "\n")
  if vim.trim(sql) == "" then
    return
  end
  local res = db.raw(state.path, sql, { readonly = false })
  if not res.ok then
    state.view_mode = "query"
    set_lines(state.buf, vim.split("SQL error:\n\n" .. (res.err or "unknown error"), "\n"))
    return
  end
  if #res.data == 0 then
    refresh(state)
    notify("statement executed — no rows returned")
    return
  end
  state.view_mode = "query"
  local lines = { "query results", "" }
  vim.list_extend(lines, res.data)
  set_lines(state.buf, lines)
end

-- Open (or focus) the SQL query pane below the view. The buffer survives the
-- pane being closed, so query text persists while the viewer is open.
local function open_query(state)
  if state.query_win and api.nvim_win_is_valid(state.query_win) then
    api.nvim_set_current_win(state.query_win)
    return
  end
  local win = api.nvim_win_is_valid(state.win) and state.win
    or vim.fn.win_findbuf(state.buf)[1]
  if not win then
    return
  end
  state.win = win
  api.nvim_set_current_win(win)
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

-- Cycle config.display_modes and re-render the current view. The mode change
-- is global (db reads the same config table), so it sticks for new queries.
local function toggle_mode(state)
  local modes = config.display_modes or { "box", "column" }
  if #modes == 0 then
    return
  end
  local idx = 1
  for i, mode in ipairs(modes) do
    if mode == config.display_mode then
      idx = i
      break
    end
  end
  config.display_mode = modes[idx % #modes + 1]
  notify("display mode: " .. config.display_mode)
  if state.current_table then
    load_table(state, state.current_table, state.offset)
  end
end

local function show_help()
  local keys = config.keymaps
  local entries = {
    { keys.table_list, "toggle the table list popup" },
    { keys.open_table, "open table under cursor (table list popup)" },
    { keys.next_page, "next page of rows" },
    { keys.prev_page, "previous page of rows" },
    { keys.refresh, "refresh table list and current table" },
    { keys.schema, "show schema for the current table" },
    { keys.toggle_mode, "cycle sqlite3 display mode" },
    { keys.goto_fk, "go to related row (foreign key under cursor)" },
    { keys.query, "open the SQL query pane" },
    { keys.run_query, "run the query (in the query pane)" },
    { keys.help, "show this help" },
    { keys.quit, "close viewer / popup / query pane" },
  }
  local key_width = 0
  for _, entry in ipairs(entries) do
    if entry[1] and entry[1] ~= "" then
      key_width = math.max(key_width, vim.fn.strdisplaywidth(entry[1]))
    end
  end
  local lines = {}
  for _, entry in ipairs(entries) do
    local lhs = entry[1]
    if lhs and lhs ~= "" then
      lines[#lines + 1] = " " .. lhs .. string.rep(" ", key_width - vim.fn.strdisplaywidth(lhs) + 2) .. entry[2]
    end
  end
  local buf, win = open_float(lines, "Help")
  for _, lhs in ipairs({ config.keymaps.help, "q", "<Esc>" }) do
    map(buf, lhs, function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end, "close help")
  end
end

local function show_schema(state)
  if not state.current_table then
    return
  end
  local res = db.raw(state.path, "PRAGMA table_info(" .. db.quote_ident(state.current_table) .. ");")
  if not res.ok then
    notify(res.err, vim.log.levels.ERROR)
    return
  end
  local buf, win = open_float(res.data, "Schema: " .. state.current_table)
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      if api.nvim_win_is_valid(win) then
        api.nvim_win_close(win, true)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
end

-- Line layout of each display mode's rendered output, as 1-based indices
-- into state.view_lines: `header`/`sep` are the header and separator/border
-- line, `data_start` is the first data row, and `trailing_border` says
-- whether the last line is a closing border (box/table) rather than data.
local MODE_LAYOUT = {
  box = { header = 2, sep = 3, data_start = 4, trailing_border = true },
  table = { header = 2, sep = 3, data_start = 4, trailing_border = true },
  column = { header = 1, sep = 2, data_start = 3, trailing_border = false },
  markdown = { header = 1, sep = 2, data_start = 3, trailing_border = false },
}

local function is_dash(ch)
  return ch == "-" or ch == "─"
end

-- Column boundaries (0-based char indices, half-open) read off a separator
-- line, e.g. "├────┼───────┼───────────┤" or "--  -----  ---------". Header
-- text may be centered (box/table right-align numeric headers) but the
-- separator's dash runs always line up with the data cells beneath them.
local function parse_column_ranges(sep_line)
  local ranges = {}
  local n = vim.fn.strchars(sep_line)
  local start
  for i = 0, n - 1 do
    if is_dash(vim.fn.strcharpart(sep_line, i, 1)) then
      start = start or i
    elseif start then
      ranges[#ranges + 1] = { start, i }
      start = nil
    end
  end
  if start then
    ranges[#ranges + 1] = { start, n }
  end
  return ranges
end

-- Resolve the SQL column name and cell text under the cursor, or nil if it
-- isn't over a data cell (header/border line, query results, empty view).
local function cell_at_cursor(state)
  if state.view_mode ~= "table" or not state.current_table then
    return nil
  end
  local layout = MODE_LAYOUT[config.display_mode]
  if not layout then
    return nil
  end
  local win = (state.win and api.nvim_win_is_valid(state.win)) and state.win or vim.fn.win_findbuf(state.buf)[1]
  if not win then
    return nil
  end
  local cursor = api.nvim_win_get_cursor(win)
  local view_idx = cursor[1] - 2 -- title + blank line precede view_lines in the buffer
  local data_end = #state.view_lines - (layout.trailing_border and 1 or 0)
  if view_idx < layout.data_start or view_idx > data_end then
    return nil
  end
  local sep_line = state.view_lines[layout.sep]
  local line = state.view_lines[view_idx]
  if not (sep_line and line) then
    return nil
  end
  local char_col = vim.fn.charidx(line, cursor[2])
  for i, r in ipairs(parse_column_ranges(sep_line)) do
    if char_col >= r[1] and char_col < r[2] then
      local col_name = state.columns and state.columns[i]
      if not col_name then
        return nil
      end
      return { column = col_name, value = vim.trim(vim.fn.strcharpart(line, r[1], r[2] - r[1])) }
    end
  end
  return nil
end

-- `gd` on a foreign-key cell: jump to the referenced table and land the
-- cursor on the referenced row.
local function goto_foreign_key(state)
  local cell = cell_at_cursor(state)
  if not cell then
    return
  end
  if cell.value == "" then
    notify("NULL — nothing to follow")
    return
  end

  local fks = db.foreign_key_list(state.path, state.current_table)
  if not fks.ok then
    notify(fks.err, vim.log.levels.ERROR)
    return
  end
  local fk
  for _, entry in ipairs(fks.data) do
    if entry.from == cell.column then
      fk = entry
      break
    end
  end
  if not fk then
    notify(("`%s` is not a foreign key"):format(cell.column))
    return
  end

  local to_col = fk.to
  if not to_col or to_col == "" then
    local pk = db.primary_key_column(state.path, fk.table)
    if not pk.ok then
      notify(pk.err, vim.log.levels.ERROR)
      return
    end
    if not pk.data then
      notify(("could not determine primary key of `%s`"):format(fk.table), vim.log.levels.ERROR)
      return
    end
    to_col = pk.data
  end

  local offset_res = db.find_row_offset(state.path, fk.table, to_col, cell.value)
  if not offset_res.ok then
    notify(offset_res.err, vim.log.levels.ERROR)
    return
  end
  if not offset_res.data then
    notify(("no row in `%s` where %s = %s"):format(fk.table, to_col, cell.value))
    return
  end

  local page_offset = math.floor(offset_res.data / config.page_size) * config.page_size
  local row_in_page = offset_res.data - page_offset
  load_table(state, fk.table, page_offset)

  local layout = MODE_LAYOUT[config.display_mode]
  local win = (state.win and api.nvim_win_is_valid(state.win)) and state.win or vim.fn.win_findbuf(state.buf)[1]
  if win and layout then
    pcall(api.nvim_win_set_cursor, win, { layout.data_start + row_in_page + 2, 0 })
  end
end

--- Take over `buf` (the buffer BufReadCmd gave us) as a viewer for `path`.
---@param path string
---@param buf integer
function M.open(path, buf)
  local existing = states[buf]
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
    scratch_opts(buf)
    set_lines(buf, { "sqlite-viewer: `" .. config.sqlite_cmd .. "` not found in PATH." })
    return
  end

  local tables = db.list_tables(path, config.include_views)
  if not tables.ok then
    notify("failed to read " .. path .. ": " .. (tables.err or "unknown error"), vim.log.levels.ERROR)
    scratch_opts(buf)
    set_lines(buf, { "sqlite-viewer: failed to read database.", "", tables.err or "" })
    return
  end

  scratch_opts(buf)
  set_lines(buf, { "Loading " .. path .. " …" })

  local state = {
    path = path,
    buf = buf,
    win = api.nvim_get_current_win(),
    tables = tables.data,
    current_table = nil,
    offset = 0,
    total_rows = 0,
    view_lines = {},
  }
  states[buf] = state

  local keys = config.keymaps
  map(buf, keys.table_list, function()
    open_table_list(state)
  end, "table list")
  map(buf, keys.refresh, function()
    refresh(state)
  end, "refresh")
  map(buf, keys.schema, function()
    show_schema(state)
  end, "show schema")
  map(buf, keys.toggle_mode, function()
    toggle_mode(state)
  end, "cycle display mode")
  map(buf, keys.goto_fk, function()
    goto_foreign_key(state)
  end, "go to related row (foreign key)")
  map(buf, keys.help, show_help, "show keymap help")
  map(buf, keys.quit, function()
    close(state)
  end, "close viewer")
  map(buf, keys.query, function()
    open_query(state)
  end, "open SQL query pane")
  map(buf, keys.next_page, function()
    page(state, 1)
  end, "next page")
  map(buf, keys.prev_page, function()
    page(state, -1)
  end, "previous page")

  api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      states[buf] = nil
      close_win(state.list_win)
      close_win(state.query_win)
      delete_buf(state.list_buf)
      delete_buf(state.query_buf)
    end,
  })

  -- 'cursorline' is window-local, not buffer-local, so leaving this buffer
  -- for another one in the same window would otherwise leave it stuck on.
  api.nvim_create_autocmd("BufLeave", {
    buffer = buf,
    callback = function()
      vim.wo[api.nvim_get_current_win()].cursorline = false
    end,
  })
  api.nvim_create_autocmd("BufEnter", {
    buffer = buf,
    callback = function()
      vim.wo[api.nvim_get_current_win()].cursorline = true
    end,
  })

  -- Window options and the initial table-list popup run via vim.schedule so
  -- we never touch window state from inside the BufReadCmd autocmd.
  vim.schedule(function()
    if states[buf] ~= state then
      return
    end
    local win = vim.fn.win_findbuf(buf)[1]
    if win then
      state.win = win
      vim.wo[win].wrap = false
      vim.wo[win].cursorline = true
    end
    render_view(state)
    if state.tables[1] then
      open_table_list(state)
    end
  end)
end

-- Exposed for testing.
function M._get_state(buf)
  return states[buf]
end

return M
