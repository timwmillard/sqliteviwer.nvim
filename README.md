# sqlite-viewer.nvim

Open a SQLite database file in Neovim and get an interactive table viewer
instead of a screen of binary garbage.

- Detects SQLite files by their 16-byte magic header — not just the extension,
  so non-SQLite `.db` files still open normally.
- Single-buffer UI: the buffer *is* the table view. Press `L` for a floating
  popup listing tables/views and `<CR>` to switch.
- Rows render as sqlite3's own output (`box` mode by default) — what you see
  is exactly what the CLI prints.
- Browse tables and views, page through rows, inspect schemas in a float.
  Browsing is strictly read-only.
- A SQL query pane (`S`) for running arbitrary statements, including writes.
- No dependencies beyond the `sqlite3` CLI. No FFI, no build step.

## Requirements

- Neovim 0.9+ (uses `vim.system` when available, falls back to `vim.fn.system`).
- The `sqlite3` binary in your `PATH` (or point `sqlite_cmd` at one).

## Install

**lazy.nvim**

```lua
{
  "timwmillard/sqlite-viewer.nvim",
  opts = {},
}
```

**packer.nvim**

```lua
use({
  "timwmillard/sqlite-viewer.nvim",
  config = function()
    require("sqlite-viewer").setup()
  end,
})
```

Calling `setup()` is optional — the plugin registers itself with defaults on
load. Call it only to change configuration.

## Usage

Just `:edit` any `*.db`, `*.sqlite`, or `*.sqlite3` file. If it is a real
SQLite database, the viewer opens; otherwise the file loads as a normal buffer.

### Keymaps (buffer-local, inside the viewer)

| Key    | Action                                             |
| ------ | -------------------------------------------------- |
| `L`    | Toggle the floating table list                     |
| `<CR>` | Open the table under the cursor (in the popup)     |
| `]p`   | Next page of rows                                  |
| `[p`   | Previous page of rows                              |
| `r`    | Refresh table list and current table               |
| `K`    | Show the current table's schema in a float         |
| `m`    | Cycle the sqlite3 display mode (`display_modes`)   |
| `S`    | Open the SQL query pane                            |
| `g?`   | Show a help popup listing these keymaps            |
| `q`    | Close the viewer (or the popup, when it's focused) |

All of these are configurable (see below). `gg`/`G` and normal movement work as
usual within the current page.

## SQL query pane

Press `S` in the viewer to open an editable SQL buffer below the view
(`filetype=sql`, so your usual SQL highlighting applies). Type a statement and
press `<CR>` in normal mode to execute it against the open database:

- Result-returning statements render sqlite3's raw output into the main view.
- **Write statements (INSERT/UPDATE/DELETE/DDL) execute for real** — the query
  pane is not read-only. After a write the viewer refreshes so the change is
  visible immediately. There is no undo; be deliberate.
- Errors render into the main view. `r` restores the current table view.
- `q` in the query pane closes just the pane; your query text is kept and `S`
  reopens it.

## Configuration

Defaults shown:

```lua
require("sqlite-viewer").setup({
  patterns = { "*.db", "*.sqlite", "*.sqlite3" }, -- files to consider
  page_size = 100,          -- rows fetched per page
  display_mode = "table",     -- any sqlite3 output mode: box, column, table, markdown, …
  display_modes = { "box", "column", "markdown", "table" }, -- cycled by `toggle_mode`
  include_views = true,     -- list views alongside tables
  sqlite_cmd = "sqlite3",   -- path to the sqlite3 binary
  keymaps = {               -- set any entry to false/"" to disable it
    table_list = "L",   -- toggle the floating table list
    open_table = "<CR>",
    next_page = "]p",
    prev_page = "[p",
    refresh = "r",
    schema = "K",
    toggle_mode = "m",  -- cycle through display_modes
    help = "g?",        -- help popup listing the keymaps
    quit = "q",
    query = "S",      -- open the SQL query pane
    run_query = "<CR>", -- execute the query buffer (normal mode)
  },
})
```

Viewer buffers use `filetype=sqliteviewer` if you want to add your own
highlights or extra keymaps via a `FileType` autocmd.

## Rendering notes

- The view is sqlite3's raw output in `display_mode` — the plugin does no
  formatting of its own. `box` mode needs sqlite3 3.33+ (2020); use
  `display_mode = "column"` on older binaries.
- BLOB cells in table pages render as `<BLOB n bytes>` — raw bytes are never
  dumped.
- Row fetches are always bounded by `LIMIT`/`OFFSET`; large tables are paged,
  never loaded whole.

## Known limitations

- Browsing is read-only (`sqlite3 -readonly`); no in-buffer cell editing yet.
  The SQL query pane is the only write path.
- Query-pane results are not paged — an unbounded SELECT renders everything
  it returns; add your own `LIMIT` on big tables.
- No filtering, sorting, or search in the view yet.
- Queries run synchronously; they are fast because fetches are bounded by
  `page_size`, but a huge table's `count(*)` or an expensive query can
  briefly block.
- Requires the `sqlite3` CLI — there are no libsqlite/FFI bindings.
