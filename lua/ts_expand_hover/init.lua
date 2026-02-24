--- Public API surface for ts-expand-hover.nvim.
--- All mutable session state lives here; sub-modules are stateless.

local M = {}

local config = require("ts_expand_hover.config")
local lsp    = require("ts_expand_hover.lsp")
local float  = require("ts_expand_hover.float")

-- Centralized session state. Sub-modules receive a reference to this table.
local state = {
  verbosity    = 0,
  generation   = 0,     -- monotonic counter for stale response rejection
  source_bufnr = nil,
  source_pos   = nil,   -- { row, col } captured in M.hover() for re-requests
  can_expand   = false, -- set by float.show() from body.canIncreaseVerbosityLevel
  requesting   = false, -- concurrent request guard (EXPN-07)
  float_winid  = nil,   -- set by float.show()
  float_bufnr  = nil,   -- set by float.show()
  source_winid = nil,   -- for focus restore on float close (Phase 2+)
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

--- Expand the current type one verbosity level.
--- Silent no-op when at max expansion or when a request is already in-flight.
local function _do_expand()
  -- EXPN-05: silent no-op when canIncreaseVerbosityLevel is falsy (nil or false).
  if not state.can_expand then return end
  -- EXPN-07: drop if a request is already in-flight.
  if state.requesting then return end

  state.verbosity = state.verbosity + 1
  state.generation = state.generation + 1
  local gen = state.generation

  lsp.request({
    bufnr     = state.source_bufnr,
    row       = state.source_pos[1],
    col       = state.source_pos[2],
    verbosity = state.verbosity,
    state     = state,
    callback  = function(body)
      vim.schedule(function()
        -- Stale response guard: discard if a newer request has completed.
        if state.generation ~= gen then return end
        float.show(body, state, function() _do_expand() end, function() _do_collapse() end)
      end)
    end,
  })
end

--- Collapse the current type one verbosity level.
--- Silent no-op when already at depth 0 or when a request is already in-flight.
local function _do_collapse()
  -- EXPN-06: silent no-op when verbosity is already at minimum.
  if state.verbosity == 0 then return end
  -- EXPN-07: drop if a request is already in-flight.
  if state.requesting then return end

  state.verbosity = state.verbosity - 1
  state.generation = state.generation + 1
  local gen = state.generation

  lsp.request({
    bufnr     = state.source_bufnr,
    row       = state.source_pos[1],
    col       = state.source_pos[2],
    verbosity = state.verbosity,
    state     = state,
    callback  = function(body)
      vim.schedule(function()
        -- Stale response guard: discard if a newer request has completed.
        if state.generation ~= gen then return end
        float.show(body, state, function() _do_expand() end, function() _do_collapse() end)
      end)
    end,
  })
end

--- Trigger expandable hover at the current cursor position.
--- Sends a quickinfo request to vtsls; falls back to vim.lsp.buf.hover() when
--- vtsls is not attached or returns an error (COMP-01, COMP-02).
function M.hover()
  local bufnr = vim.api.nvim_get_current_buf()
  -- Capture source context synchronously before the async callback fires.
  state.source_bufnr = bufnr
  state.verbosity    = 0

  local cursor = vim.api.nvim_win_get_cursor(0)
  -- nvim_win_get_cursor returns { row, col } where row is 1-indexed.
  -- Convert to 0-indexed row; lsp.lua adds 1 back for tsserver.
  local row = cursor[1] - 1
  local col = cursor[2] -- already 0-indexed; lsp.lua adds 1 for tsserver

  -- Capture position for expand/collapse re-requests targeting the same symbol.
  state.source_pos = { row, col }

  lsp.request({
    bufnr     = bufnr,
    row       = row,
    col       = col,
    verbosity = state.verbosity,
    state     = state,
    callback  = function(body)
      vim.schedule(function()
        float.show(body, state, function() _do_expand() end, function() _do_collapse() end)
      end)
    end,
  })
end

return M
