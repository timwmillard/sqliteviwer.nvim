local M = {}

-- SQLite database files start with this exact 16-byte header (trailing NUL).
local MAGIC = "SQLite format 3\0"

--- Check whether the file at `path` is a SQLite database by reading its
--- magic header. Extension is never trusted; the header is the source of truth.
---@param path string
---@return boolean
function M.is_sqlite(path)
  local f = io.open(path, "rb")
  if not f then
    return false
  end
  local header = f:read(16)
  f:close()
  return header == MAGIC
end

return M
