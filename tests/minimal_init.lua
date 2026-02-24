-- Bootstrap plenary.nvim and the plugin for headless test execution.
local plenary_path = vim.fn.stdpath("data") .. "/site/pack/vendor/start/plenary.nvim"

if vim.fn.empty(vim.fn.glob(plenary_path)) > 0 then
  vim.fn.system({
    "git", "clone", "--depth", "1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_path,
  })
end

vim.opt.rtp:prepend(".")           -- plugin root
vim.opt.rtp:append(plenary_path)   -- plenary
vim.cmd("runtime! plugin/plenary.vim") -- activate plenary commands
