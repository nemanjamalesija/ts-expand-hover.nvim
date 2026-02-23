--- Configuration module for ts-expand-hover.nvim.
--- Pure Lua: no NeoVim API calls at module load time.

local M = {}

local defaults = {
  keymaps = {
    hover    = "K",
    expand   = "+",
    collapse = "-",
    close    = { "q", "<Esc>" },
  },
  float = {
    border     = "rounded",
    max_width  = 80,
    max_height = 30,
  },
}

local _config = {}

--- Merge user opts with defaults and store the result.
---@param opts table|nil
function M.setup(opts)
  _config = vim.tbl_deep_extend("force", defaults, opts or {})
end

--- Return the active config table.
---@return table
function M.get()
  return _config
end

return M
