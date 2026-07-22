# sqlite-viewer.nvim

Open a SQLite database file in Neovim and get an interactive table viewer
instead of a screen of binary garbage.

- Detects SQLite files by their 16-byte magic header — not just the extension,
  so non-SQLite `.db` files still open normally.
- Two-pane UI: a table list on the left, a paged results grid on the right.
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

| Key    | Action                                          |
| ------ | ----------------------------------------------- |
| `<CR>` | Open the table under the cursor (table list)    |
| `]p`   | Next page of rows                               |
| `[p`   | Previous page of rows                           |
| `r`    | Refresh table list and current table            |
| `K`    | Show the current table's schema in a float      |
| `S`    | Open the SQL query pane                         |
| `q`    | Close the viewer                                |

All of these are configurable (see below). `gg`/`G` and normal movement work as
usual within the current page.

## SQL query pane

Press `S` in the viewer to open an editable SQL buffer below the grid
(`filetype=sql`, so your usual SQL highlighting applies). Type a statement and
press `<CR>` in normal mode to execute it against the open database:

- SELECTs render into the grid pane (`query — N rows`); results are capped at
  `page_size` rows for display.
- **Write statements (INSERT/UPDATE/DELETE/DDL) execute for real** — the query
  pane is not read-only. After a write the viewer refreshes so the change is
  visible immediately. There is no undo; be deliberate.
- Errors render into the grid pane. `r` restores the current table view.
- `q` in the query pane closes just the pane; your query text is kept and `S`
  reopens it.
- One result-returning statement per run (multiple writes in one run are fine,
  e.g. a small seed script).

## Configuration

Defaults shown:

```lua
require("sqlite-viewer").setup({
  patterns = { "*.db", "*.sqlite", "*.sqlite3" }, -- files to consider
  page_size = 100,          -- rows fetched per page
  max_col_width = 40,       -- cells wider than this are truncated with …
  include_views = true,     -- list views alongside tables
  sqlite_cmd = "sqlite3",   -- path to the sqlite3 binary
  keymaps = {               -- set any entry to false/"" to disable it
    open_table = "<CR>",
    next_page = "]p",
    prev_page = "[p",
    refresh = "r",
    schema = "K",
    quit = "q",
    query = "S",      -- open the SQL query pane
    run_query = "<CR>", -- execute the query buffer (normal mode)
  },
})
```

Viewer buffers use `filetype=sqliteviewer` if you want to add your own
highlights or extra keymaps via a `FileType` autocmd.

## Rendering notes

- `NULL` cells render as `NULL`.
- BLOB cells render as `<BLOB n bytes>` — raw bytes are never dumped.
- Embedded newlines are collapsed to `↵` so every row stays on one line.
- Row fetches are always bounded by `LIMIT`/`OFFSET`; large tables are paged,
  never loaded whole.

## Known limitations

- Browsing is read-only (`sqlite3 -readonly`); no in-grid cell editing. The
  SQL query pane is the only write path.
- Query-pane results are not paged — only the first `page_size` rows display.
- No filtering, sorting, or search in the grid yet.
- Queries run synchronously; they are fast because fetches are bounded by
  `page_size`, but a huge table's `count(*)` or an expensive query can
  briefly block.
- Requires the `sqlite3` CLI — there are no libsqlite/FFI bindings.
