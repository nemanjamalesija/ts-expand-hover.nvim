--- Public API surface for ts-expand-hover.nvim.
--- All mutable session state lives here; sub-modules are stateless.

local M = {}

local config = require("ts_expand_hover.config")

-- Centralized session state. Sub-modules receive a reference to this table.
local state = {
  verbosity    = 0,
  source_bufnr = nil,
  source_pos   = nil,   -- { row, col }
  requesting   = false, -- concurrent request guard (EXPN-07)
  float_winid  = nil,   -- Phase 2+
  float_bufnr  = nil,   -- Phase 2+
}

--- Return the session state table.
--- Sub-modules use this to read and update state without owning it.
---@return table
function M.get_state()
  return state
end

--- Initialize the plugin with user options.
--- Compatible with lazy.nvim `opts` table convention.
---@param opts table|nil
---@return table M for chaining
function M.setup(opts)
  config.setup(opts)
  return M
end

--- Trigger expandable hover at the current cursor position.
--- Wired to the vtsls request pipeline in Task 2.
function M.hover()
  vim.notify("ts-expand-hover: hover() not yet wired", vim.log.levels.DEBUG)
end

return M
