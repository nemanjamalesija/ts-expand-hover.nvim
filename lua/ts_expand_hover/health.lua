--- Checkhealth module for ts-expand-hover.nvim.
--- Run via :checkhealth ts_expand_hover

local M = {}

M.check = function()
  vim.health.start("ts_expand_hover")

  -- 1. NeoVim version
  local v = vim.version()
  vim.health.info(string.format("NeoVim version: %d.%d.%d", v.major, v.minor, v.patch))
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("NeoVim >= 0.10 (required)")
  else
    vim.health.error("NeoVim 0.10+ required", { "Upgrade NeoVim to 0.10 or later" })
  end

  -- 2. vtsls detection
  local get_clients = vim.lsp.get_clients or vim.lsp.get_active_clients
  local clients = get_clients({ name = "vtsls" })

  if #clients == 0 then
    vim.health.warn("vtsls is not attached to any buffer", { "Open a TypeScript file and ensure vtsls is configured" })
    return
  end

  local client = clients[1]
  local server_info = client.server_info or {}
  local vtsls_version = server_info.version or "unknown"
  vim.health.info("vtsls version: " .. vtsls_version)
  vim.health.ok("vtsls is attached")

  -- 3. TypeScript version — defensive parse from server_info.version
  local ts_version = "unknown"
  if server_info.version then
    local extracted = server_info.version:match("typescript/([%d%.]+)")
    if extracted then ts_version = extracted end
  end
  if ts_version ~= "unknown" then
    vim.health.info("TypeScript version: " .. ts_version)
  else
    vim.health.warn("TypeScript version could not be detected", { "Check :LspInfo for server details" })
  end
end

return M
