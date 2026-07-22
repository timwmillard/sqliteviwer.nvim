-- Turn row objects into monospace-aligned text lines.

local M = {}

local NEWLINE_SYMBOL = "↵"

-- Convert a decoded JSON cell value to display text.
local function to_text(value)
  if value == nil or value == vim.NIL then
    return "NULL"
  end
  local text = tostring(value)
  text = text:gsub("\r\n", NEWLINE_SYMBOL):gsub("[\r\n]", NEWLINE_SYMBOL)
  return text
end

-- Truncate to at most `max_width` display columns, appending "…".
local function truncate(text, max_width)
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  -- pre-cut huge cells so the char-by-char loop below stays cheap
  if #text > max_width * 4 then
    text = vim.fn.strcharpart(text, 0, max_width * 2)
  end
  local chars = vim.fn.strchars(text)
  while chars > 0 do
    local head = vim.fn.strcharpart(text, 0, chars)
    if vim.fn.strdisplaywidth(head) <= max_width - 1 then
      return head .. "…"
    end
    chars = chars - 1
  end
  return "…"
end

local function pad(text, width)
  return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
end

--- Render rows as an aligned grid.
---@param columns string[] ordered column names
---@param rows table[] list of { [column] = value } row objects
---@param opts { max_col_width: integer }|nil
---@return string[] lines header row, separator, then one line per row
function M.grid(columns, rows, opts)
  opts = opts or {}
  local max_col_width = opts.max_col_width or 40

  local header_cells = {}
  local widths = {}
  for i, col in ipairs(columns) do
    header_cells[i] = truncate(col, max_col_width)
    widths[i] = vim.fn.strdisplaywidth(header_cells[i])
  end

  local cells = {}
  for r, row in ipairs(rows) do
    cells[r] = {}
    for i, col in ipairs(columns) do
      local text = truncate(to_text(row[col]), max_col_width)
      cells[r][i] = text
      widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(text))
    end
  end

  local sep = {}
  for i, w in ipairs(widths) do
    sep[i] = string.rep("─", w)
  end

  local function join(parts, glue)
    return (table.concat(parts, glue):gsub("%s+$", ""))
  end

  local padded_header = {}
  for i, cell in ipairs(header_cells) do
    padded_header[i] = pad(cell, widths[i])
  end

  local lines = {
    join(padded_header, " │ "),
    table.concat(sep, "─┼─"),
  }
  for r = 1, #rows do
    local out = {}
    for i = 1, #columns do
      out[i] = pad(cells[r][i], widths[i])
    end
    lines[#lines + 1] = join(out, " │ ")
  end
  return lines
end

return M
