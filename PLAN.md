# Implementation Plan: `sqlite-viewer.nvim`

A Neovim plugin that detects when a SQLite file is opened and replaces the buffer
with an interactive, read-only table viewer.

## Scope (v1)

**In scope**
- Auto-detect SQLite files on open (by content magic header, not just extension).
- Replace the buffer with a viewer UI: a table list + a paged results grid.
- Browse tables, page through rows, view schema.
- Read-only. Shell out to the `sqlite3` binary in `PATH`.

**Out of scope (later versions)**
- Editing cells / writing back to the database.
- Arbitrary SQL query input.
- libsqlite/FFI bindings — v1 depends only on the `sqlite3` CLI.
- Filtering, sorting, search within results.

## Dependencies

- Neovim 0.9+ (uses `vim.system` if available; fall back to `vim.fn.system`).
- `sqlite3` binary available in `PATH`. Detect at startup and fail gracefully
  with a clear message if missing.

## Architecture

Suggested module layout under `lua/sqlite-viewer/`:

```
lua/sqlite-viewer/
  init.lua        -- setup(), config, autocmd registration
  detect.lua      -- magic-header check
  db.lua          -- all sqlite3 CLI calls, JSON parsing
  ui.lua          -- buffer/window creation, rendering, keymaps
  render.lua      -- table formatting (column widths, NULL/BLOB handling)
plugin/
  sqlite-viewer.lua  -- guard + require setup on load (optional)
```

## Component details

### 1. Detection (`detect.lua`)

- SQLite files begin with the 16-byte magic string `SQLite format 3\0`
  (the last byte is a NUL).
- `is_sqlite(path)`: open the file in binary mode, read the first 16 bytes,
  compare against the magic string. Return boolean.
- Do NOT rely on extension alone — `.db` is heavily overloaded. Extension can be
  used to *decide whether to bother checking*, but the header is the source of
  truth.

### 2. Autocommand registration (`init.lua`)

- On `setup(opts)`, create an autocmd group `SqliteViewer`.
- Register `BufReadCmd` for the configured patterns (default
  `*.db,*.sqlite,*.sqlite3`).
- `BufReadCmd` is important: it means *we* own loading the buffer, so Neovim
  won't slurp the binary content in as garbage text. Inside the callback:
  1. Get the file path from `vim.fn.expand("<amatch>")`.
  2. Run `detect.is_sqlite(path)`. If false, fall back to normal read
     (`:edit` behavior) so we don't hijack non-SQLite `.db` files.
  3. If true, hand off to `ui.open(path)`.
- Make patterns and behavior configurable via `opts`.

### 3. Database layer (`db.lua`)

All functions shell out to `sqlite3 <path> -json "<query>"` and parse the JSON
result. Use `-json` output mode so parsing is `vim.json.decode`, not text
scraping. Always pass queries as separate args; never string-interpolate table
names/user values into SQL without escaping (see Safety below).

Functions:
- `db.check_binary()` -> bool. Verify `sqlite3` is callable.
- `db.list_tables(path)` -> list of table names.
  `SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;`
  (Consider also listing views: `type IN ('table','view')`.)
- `db.table_info(path, table)` -> column metadata via `PRAGMA table_info(...)`.
- `db.row_count(path, table)` -> `SELECT count(*) FROM "<table>";`
- `db.rows(path, table, limit, offset)` ->
  `SELECT * FROM "<table>" LIMIT <limit> OFFSET <offset>;`
- Return a structured result: `{ ok = bool, data = ..., err = string }`.
  Surface `sqlite3` stderr on failure rather than swallowing it.

**Async note:** these are fast for small DBs but can block on large tables.
Prefer `vim.system(...)` (async, Neovim 0.10+) with a callback, falling back to
synchronous `vim.fn.system` on older versions. v1 may ship synchronous for
simplicity as long as row fetches are bounded by `LIMIT`.

### 4. UI (`ui.lua`)

Layout: a single tab/window arrangement with two panes.
- **Left pane** (narrow, ~25 cols): list of tables. Cursor line = selected
  table. `<CR>` loads it into the right pane.
- **Right pane** (main): rendered grid of the current table's rows, plus a
  header line showing `table_name — rows X–Y of N`.

Buffers:
- All viewer buffers are scratch: `buftype=nofile`, `bufhidden=wipe`,
  `swapfile=false`, `modifiable=false` (toggle to true only while rendering).
- Set a custom `filetype=sqliteviewer` so users can style/extend it.

Keymaps (buffer-local, inside the viewer):
- `<CR>` on a table name — open that table.
- `]p` / `[p` (or `<C-f>`/`<C-b>`) — next / previous page of rows.
- `gg`/`G` behave normally within the current page.
- `r` — refresh current table.
- `q` — close the viewer.
- `K` or `gs` — show schema (`table_info`) for the current table in a float.
- Document these in the README and expose them as overridable.

Paging:
- Keep `state = { path, current_table, offset, page_size, total_rows }`.
- `page_size` configurable (default e.g. 100).
- Page navigation adjusts `offset`, refetches via `db.rows`, re-renders.

### 5. Rendering (`render.lua`)

Turn a list of row objects into aligned text lines. This is the fiddliest part.

- Column order: take from `table_info` (or the keys of the first row) so order is
  stable and matches schema.
- Compute each column's display width = max(header width, max cell width),
  capped at a configurable `max_col_width` (default e.g. 40) with truncation
  (append `…`).
- Cell formatting:
  - `NULL` -> render as a distinct token, e.g. `NULL` (consider a highlight).
  - BLOB -> don't dump raw bytes; render `<BLOB n bytes>` or hex-preview.
  - Multi-line text -> collapse newlines to a symbol (e.g. `↵`) so rows stay
    one line.
- Emit: a header row, a separator row (`─┼─` style or simple `-`), then data
  rows. Keep it monospace-aligned.
- Optionally add highlights via `nvim_buf_add_highlight` / extmarks: header line,
  NULL cells, alternating row shading. Nice-to-have, not required for v1.

## Configuration (default shape)

```lua
require("sqlite-viewer").setup({
  patterns = { "*.db", "*.sqlite", "*.sqlite3" },
  page_size = 100,
  max_col_width = 40,
  include_views = true,
  sqlite_cmd = "sqlite3",   -- allow overriding the binary path
  keymaps = {               -- allow user overrides
    open_table = "<CR>",
    next_page = "]p",
    prev_page = "[p",
    refresh = "r",
    schema = "K",
    quit = "q",
  },
})
```

## Safety / correctness notes

- **SQL identifier injection:** table names come from the DB, but still quote
  them with double-quotes and escape embedded quotes when interpolating into
  `SELECT * FROM "<table>"`. Never interpolate raw values.
- **Prefer arg-passing over shell string building** where possible. When using
  `vim.system`, pass an argv array (`{ "sqlite3", path, "-json", query }`) so the
  shell doesn't re-interpret the path or query. Avoid building one big shell
  string.
- **Large tables:** always bound row fetches with `LIMIT`. Never `SELECT *`
  without a limit into the buffer.
- **Non-SQLite `.db` files:** the magic-header check must gate the takeover; on a
  miss, fall through to a normal buffer read so we don't break unrelated files.
- **Missing binary:** if `sqlite3` isn't found, show one clear notification and
  do nothing else (don't error on every file open).
- **Empty / zero-table DBs:** render an empty-state message, not a crash.
- **Weird schemas:** tables with zero rows, columns with odd names/spaces, WITHOUT
  ROWID tables — all should just render cleanly.

## Suggested build order

1. `detect.is_sqlite` + a manual `:lua` test against a real and a fake `.db`.
2. `db.check_binary` + `db.list_tables`, printed to `:messages`.
3. `db.rows` + `render` producing an aligned grid string (test in isolation).
4. `ui.open` wiring: two panes, table list, render first table.
5. `BufReadCmd` autocmd hooking `ui.open`, with the detect gate + fallback.
6. Paging, schema float, refresh, keymaps.
7. Polish: highlights, empty states, config surface, README.

## Testing checklist

- Real SQLite DB with several tables and mixed column types.
- A `.db` file that is NOT SQLite (e.g. some other binary) — must fall through.
- Empty database (no tables).
- Table with 0 rows.
- Table with NULLs, long text, and a BLOB column.
- Very wide table (many columns) and very tall table (paging).
- `sqlite3` binary absent from `PATH`.
- Table name containing a space or a reserved word.

## Deliverables

- The plugin under `lua/sqlite-viewer/` (+ optional `plugin/` guard).
- A `README.md`: install (lazy.nvim/packer snippets), `setup()` options, keymaps,
  known limitations (read-only, requires `sqlite3` CLI).
- No test framework required for v1, but the manual testing checklist above
  should pass.
