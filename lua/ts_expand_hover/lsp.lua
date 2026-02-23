--- vtsls request pipeline for ts-expand-hover.nvim.
--- Sends quickinfo with verbosityLevel; falls back to vim.lsp.buf.hover() on any failure.

local M = {}

-- Compat shim: vim.lsp.get_active_clients() deprecated in NeoVim 0.10, removed in 0.11.
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients

--- Find the vtsls client attached to the given buffer, or nil.
---@param bufnr integer
---@return table|nil
local function find_vtsls_client(bufnr)
  local clients = get_clients({ bufnr = bufnr, name = "vtsls" })
  return clients[1]
end

--- Send a quickinfo request to vtsls with verbosityLevel.
--- Falls back to vim.lsp.buf.hover() when vtsls is not attached (COMP-01)
--- or when the response indicates an error or TypeScript < 5.9 (COMP-02).
--- Drops silently if a request is already in-flight (EXPN-07).
---
---@param opts { bufnr: integer, row: integer, col: integer, verbosity: integer, state: table, callback: fun(body: table) }
function M.request(opts)
  -- COMP-01: fall back when vtsls is not attached to this buffer.
  local client = find_vtsls_client(opts.bufnr)
  if not client then
    vim.lsp.buf.hover()
    return
  end

  -- EXPN-07: drop silently if a request is already in-flight.
  if opts.state.requesting then
    return
  end
  opts.state.requesting = true

  -- row is 0-indexed (from nvim_win_get_cursor); tsserver line is 1-indexed.
  -- col is 0-indexed (from nvim_win_get_cursor); tsserver offset is 1-indexed.
  local params = {
    command   = "typescript.tsserverRequest",
    arguments = {
      "quickinfo",
      {
        file           = vim.api.nvim_buf_get_name(opts.bufnr),
        line           = opts.row + 1,
        offset         = opts.col + 1,
        verbosityLevel = opts.verbosity,
      },
    },
  }

  client:request("workspace/executeCommand", params, function(err, result)
    -- Always clear the in-flight guard first.
    opts.state.requesting = false

    -- COMP-02: fall back on any error or missing body (covers TS < 5.9).
    if err or not result or not result.body then
      vim.schedule(function()
        vim.lsp.buf.hover()
      end)
      return
    end

    opts.callback(result.body)
  end, opts.bufnr)
end

return M
