--- Checkhealth module for ts-expand-hover.nvim.
--- Run via :checkhealth ts_expand_hover

local M = {}

--- The TypeScript 7 server sends canIncreaseVerbosity only when the client
--- declared this capability. Without it the plugin never learns that a type
--- can expand, so + does nothing.
---@param client table
local function check_verbosity_capability(client)
  -- NeoVim 0.11+ keeps the resolved capabilities on client.capabilities,
  -- 0.10 keeps them on client.config.capabilities.
  local caps = client.capabilities or client.config.capabilities or {}
  local declared = caps.experimental and caps.experimental.hoverVerbosityLevel
  if declared then
    vim.health.ok("experimental.hoverVerbosityLevel capability is declared")
  else
    vim.health.error(
      "experimental.hoverVerbosityLevel capability is not declared, so + does nothing",
      { "Add capabilities = { experimental = { hoverVerbosityLevel = true } } to the tsc LSP config (see README)" }
    )
  end
end

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

  -- 2. server detection
  local client, name = require("ts_expand_hover.lsp").find_client()
  if not client then
    vim.health.warn(
      "no supported TypeScript server is attached (vtsls, tsc or tsgo)",
      { "Open a TypeScript file and make sure vtsls or the TypeScript 7 server (tsc) is configured" }
    )
    return
  end
  vim.health.ok(name .. " is attached")
  local server_info = client.server_info or {}

  if name ~= "vtsls" then
    -- The TypeScript 7 server reports the TypeScript version as its own.
    vim.health.info("TypeScript version: " .. (server_info.version or "unknown"))
    check_verbosity_capability(client)
    return
  end

  vim.health.info("vtsls version: " .. (server_info.version or "unknown"))

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
