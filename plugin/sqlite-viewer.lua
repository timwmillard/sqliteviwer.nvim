if vim.g.loaded_sqlite_viewer then
  return
end
vim.g.loaded_sqlite_viewer = 1

if vim.fn.has("nvim-0.9") ~= 1 then
  vim.notify("sqlite-viewer requires Neovim 0.9+", vim.log.levels.ERROR)
  return
end

-- Auto-setup with defaults; a later (or earlier) user setup() call wins
-- because setup() re-registers its augroup with clear = true.
local sqlite_viewer = require("sqlite-viewer")
if not sqlite_viewer.did_setup then
  sqlite_viewer.setup()
end
