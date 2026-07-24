local M = {}

M.defaults = {
  patterns = { "*.db", "*.sqlite", "*.sqlite3" },
  page_size = 100,
  display_mode = "box", -- any sqlite3 output mode: box, column, table, markdown, …
  display_modes = { "box", "column", "markdown", "table" }, -- cycled by keymaps.toggle_mode
  include_views = true,
  sqlite_cmd = "sqlite3", -- override to use a different binary path
  keymaps = { -- set any entry to false/"" to disable it
    table_list = "T", -- popup listing tables/views
    open_table = "<CR>",
    next_page = "]p",
    prev_page = "[p",
    refresh = "r",
    schema = "K",
    toggle_mode = "m", -- cycle through display_modes
    help = "g?", -- popup listing these keymaps
    quit = "q",
    query = "S",
    run_query = "<CR>",
  },
}

M.config = vim.deepcopy(M.defaults)
M.did_setup = false

-- BufReadCmd suppressed the normal file read, so on a non-SQLite file we have
-- to load the contents ourselves and replay the usual post-read autocmds.
local function fallback_read(buf, path)
  local escaped = vim.fn.fnameescape(path)
  vim.bo[buf].modifiable = true
  local ok, err = pcall(vim.cmd, "silent keepalt keepjumps read ++edit " .. escaped)
  if ok then
    -- :read inserts below the cursor, leaving a stray empty first line
    vim.cmd("silent keepjumps 1delete _")
  else
    vim.notify("sqlite-viewer: " .. tostring(err), vim.log.levels.ERROR)
  end
  vim.bo[buf].modified = false
  pcall(vim.cmd, "doautocmd BufReadPost " .. escaped)
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- tbl_deep_extend merges lists element-wise; a user list must replace ours
  if opts and opts.display_modes then
    M.config.display_modes = vim.deepcopy(opts.display_modes)
  end
  M.did_setup = true

  require("sqlite-viewer.db").setup(M.config)
  require("sqlite-viewer.ui").setup(M.config)

  local group = vim.api.nvim_create_augroup("SqliteViewer", { clear = true })
  vim.api.nvim_create_autocmd("BufReadCmd", {
    group = group,
    pattern = M.config.patterns,
    desc = "Open SQLite files in the viewer",
    callback = function(args)
      local path = args.match
      if require("sqlite-viewer.detect").is_sqlite(path) then
        require("sqlite-viewer.ui").open(path, args.buf)
      else
        fallback_read(args.buf, path)
      end
    end,
  })
end

return M
