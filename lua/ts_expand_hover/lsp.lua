--- Request pipeline for ts-expand-hover.nvim.
--- Talks to vtsls or to the TypeScript 7 server (tsc, also known as tsgo) and
--- turns both answers into one shape before the float sees them:
---   { lines = string[], can_expand = boolean }
--- Falls back to vim.lsp.buf.hover() on any failure.

local M = {}

-- Compat shim: vim.lsp.get_active_clients() deprecated in NeoVim 0.10, removed in 0.11.
local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients

-- vtsls comes first so a buffer with both servers attached keeps the vtsls
-- behaviour. "tsgo" is the older nvim-lspconfig name for the TypeScript 7
-- server, kept for setups that still use it.
local SERVERS = { "vtsls", "tsc", "tsgo" }

--- Find the first supported client, attached to the given buffer or, when
--- bufnr is nil, to any buffer.
---@param bufnr integer|nil
---@return table|nil client
---@return string|nil name
function M.find_client(bufnr)
  for _, name in ipairs(SERVERS) do
    local client = get_clients({ bufnr = bufnr, name = name })[1]
    if client then return client, name end
  end
  return nil, nil
end

local function fallback_to_builtin_hover()
  vim.schedule(function()
    vim.lsp.buf.hover()
  end)
end

--- Flatten a SymbolDisplayPart[] array or plain string to a single string.
--- Returns the input unchanged when it is already a string.
--- Returns nil for any other type (nil, boolean, number).
---@param val string|table|nil SymbolDisplayPart[] or plain string
---@return string|nil
local function flatten_display_parts(val)
  if type(val) == "string" then return val end
  if type(val) == "table" then
    local texts = {}
    for _, part in ipairs(val) do
      if part.text then texts[#texts + 1] = part.text end
    end
    return table.concat(texts)
  end
  return nil
end

--- Turn a tsserver quickinfo body into markdown lines: the type inside a
--- typescript fence, then the documentation text, then the JSDoc tags.
---@param body table quickinfo body with displayString, documentation, tags
---@return string[]
local function quickinfo_lines(body)
  if not body.displayString then
    return { "(no type info)" }
  end
  local result = { "```typescript" }
  for _, line in ipairs(vim.split(body.displayString, "\n", { plain = true })) do
    result[#result + 1] = line
  end
  result[#result + 1] = "```"

  local doc = flatten_display_parts(body.documentation)
  if doc and doc ~= "" then
    result[#result + 1] = ""
    for _, line in ipairs(vim.split(doc, "\n", { plain = true })) do
      result[#result + 1] = line
    end
  end

  if body.tags and #body.tags > 0 then
    result[#result + 1] = ""
    for _, tag in ipairs(body.tags) do
      local text = flatten_display_parts(tag.text)
      local tag_lines = vim.split(text or "", "\n", { plain = true })
      result[#result + 1] = string.format("**@%s** %s", tag.name, tag_lines[1] or "")
      for i = 2, #tag_lines do
        result[#result + 1] = tag_lines[i]
      end
    end
  end

  return result
end

--- vtsls has no hover verbosity of its own. It exposes tsserver's quickinfo
--- command through workspace/executeCommand, and quickinfo takes verbosityLevel.
---@param client table
---@param opts table see M.request
local function request_vtsls(client, opts)
  -- row and col are 0-indexed (from nvim_win_get_cursor); tsserver wants 1-indexed.
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
    opts.state.requesting = false

    -- Any error or missing body (TypeScript < 5.9 included) falls back (COMP-02).
    if err or not result or not result.body then
      fallback_to_builtin_hover()
      return
    end

    opts.callback({
      lines      = quickinfo_lines(result.body),
      can_expand = result.body.canIncreaseVerbosityLevel or false,
    })
  end, opts.bufnr)
end

--- The TypeScript 7 server takes verbosityLevel on a plain textDocument/hover
--- request and answers with markdown plus canIncreaseVerbosity. It sends
--- canIncreaseVerbosity only when the client declared the
--- experimental.hoverVerbosityLevel capability; without it the flag is missing,
--- so expand stays a no-op. :checkhealth ts_expand_hover reports that case.
---@param client table
---@param opts table see M.request
local function request_tsgo(client, opts)
  local params = {
    textDocument   = { uri = vim.uri_from_bufnr(opts.bufnr) },
    position       = {
      line      = opts.row,
      character = vim.lsp.util.character_offset(opts.bufnr, opts.row, opts.col, client.offset_encoding),
    },
    verbosityLevel = opts.verbosity,
  }

  client:request("textDocument/hover", params, function(err, result)
    opts.state.requesting = false

    if err or not result or not result.contents then
      fallback_to_builtin_hover()
      return
    end

    opts.callback({
      lines      = vim.lsp.util.convert_input_to_markdown_lines(result.contents),
      can_expand = result.canIncreaseVerbosity or false,
    })
  end, opts.bufnr)
end

--- Ask the attached TypeScript server for the hover at verbosity level
--- opts.verbosity and hand the normalized answer to opts.callback.
--- Falls back to vim.lsp.buf.hover() when no supported server is attached
--- (COMP-01) or when the server answers with an error (COMP-02).
--- Drops silently if a request is already in-flight (EXPN-07).
---
---@param opts { bufnr: integer, row: integer, col: integer, verbosity: integer, state: table, callback: fun(hover: { lines: string[], can_expand: boolean }) }
function M.request(opts)
  local client, name = M.find_client(opts.bufnr)
  if not client then
    vim.lsp.buf.hover()
    return
  end

  if opts.state.requesting then
    return
  end
  opts.state.requesting = true

  if name == "vtsls" then
    request_vtsls(client, opts)
  else
    request_tsgo(client, opts)
  end
end

return M
