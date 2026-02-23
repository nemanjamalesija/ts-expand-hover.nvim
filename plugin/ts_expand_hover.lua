--- Entry point for ts-expand-hover.nvim.
--- Runs at plugin load time: version guard + keymap registration only.
--- No module requires at the top level — startup cost matters.

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("ts-expand-hover.nvim requires NeoVim 0.10+", vim.log.levels.ERROR)
  return
end

-- Deferred require: the module is loaded only on first keymap invocation.
vim.keymap.set("n", "K", function()
  require("ts_expand_hover").hover()
end, { desc = "TypeScript expandable hover" })
