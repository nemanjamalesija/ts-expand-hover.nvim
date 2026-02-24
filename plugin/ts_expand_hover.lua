--- Entry point for ts-expand-hover.nvim.
--- Runs at plugin load time: version guard only.
--- Keymap registration is deferred to M.setup() — users MUST call setup().

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("ts-expand-hover.nvim requires NeoVim 0.10+", vim.log.levels.ERROR)
  return
end
