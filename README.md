# ts-expand-hover.nvim

Expandable TypeScript type inspection for NeoVim. Uses TypeScript 5.9's `verbosityLevel` API to let you progressively expand and collapse type aliases directly inside a hover float.

## Features

- **Progressive type expansion** — press `+` to expand type aliases one level at a time, `-` to collapse
- **In-place float updates** — content updates without closing or repositioning the float
- **Treesitter highlighting** — TypeScript code fences are syntax-highlighted via treesitter markdown injection
- **Documentation and JSDoc** — documentation text and `@param`/`@returns`/`@example` tags rendered below the type block
- **Configurable keymaps** — override or disable any keymap (hover, expand, collapse, close)
- **Configurable float** — border style, max width, max height
- **Graceful fallback** — falls back to `vim.lsp.buf.hover()` when vtsls is not attached or TypeScript < 5.9
- **Concurrent request guard** — rapid key presses are silently dropped; stale responses from prior hover sessions are discarded

## Requirements

- **NeoVim 0.10+**
- **[vtsls](https://github.com/yioneko/vtsls)** v0.2.9+ (v0.3.0+ recommended — bundles TypeScript 5.9)
- **TypeScript 5.9+** (for `verbosityLevel` support in tsserver's quickinfo)

## Installation

### lazy.nvim

```lua
{
  "nemanjamalesija/ts-expand-hover.nvim",
  ft = { "typescript", "typescriptreact" },
  opts = {
    -- Recommended: avoid conflicts with distros/plugins that already map `K`
    keymaps = { hover = "<leader>th" },
  },
}
```

### packer.nvim

```lua
use {
  "nemanjamalesija/ts-expand-hover.nvim",
  ft = { "typescript", "typescriptreact" },
  config = function()
    require("ts_expand_hover").setup()
  end,
}
```

### mini.deps

```lua
MiniDeps.add({ source = "nemanjamalesija/ts-expand-hover.nvim" })
require("ts_expand_hover").setup()
```

### Manual

Clone to your NeoVim packages directory:

```sh
git clone https://github.com/nemanjamalesija/ts-expand-hover.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/ts-expand-hover.nvim
```

Then add to your config:

```lua
require("ts_expand_hover").setup()
```

## Setup

Calling `setup()` with no arguments uses all defaults:

```lua
require("ts_expand_hover").setup()
```

Full configuration with defaults shown:

```lua
require("ts_expand_hover").setup({
  keymaps = {
    hover    = "K",           -- normal mode key to open hover float
    expand   = "+",           -- expand type one level (inside float)
    collapse = "-",           -- collapse type one level (inside float)
    close    = { "q", "<Esc>" },  -- close float and return to source
  },
  float = {
    border     = "rounded",   -- border style: "rounded", "single", "double", "none"
    max_width  = 80,          -- maximum float width in columns
    max_height = 30,          -- maximum float height in lines
  },
})
```

### Custom keymaps example

```lua
require("ts_expand_hover").setup({
  keymaps = {
    hover    = "<leader>th",
    expand   = "]t",
    collapse = "[t",
  },
})
```

### Recommended binding strategy

Many Neovim distributions and plugins already map `K` (often buffer-local for LSP hover),
which can override global mappings. To avoid conflicts, use a custom binding:

```lua
require("ts_expand_hover").setup({
  keymaps = {
    hover = "<leader>th",
  },
})
```

If you want to keep `K`, prefer a TypeScript-only mapping:

```lua
require("ts_expand_hover").setup({
  keymaps = { hover = false }, -- disable global mapping
})

vim.api.nvim_create_autocmd("FileType", {
  pattern = { "typescript", "typescriptreact" },
  callback = function(ev)
    vim.keymap.set("n", "K", require("ts_expand_hover").hover, {
      buffer = ev.buf,
      desc = "TypeScript expandable hover",
    })
  end,
})
```

### Disabling keymaps

Set any keymap to `false` to prevent the plugin from registering it. This is useful if you want to bind the hover function yourself:

```lua
require("ts_expand_hover").setup({
  keymaps = { hover = false },
})

-- Bind it yourself
vim.keymap.set("n", "gh", require("ts_expand_hover").hover, { desc = "TS hover" })
```

## Keymaps

| Key | Scope | Action |
|-----|-------|--------|
| `K` | Normal mode (global) | Open hover float at cursor |
| `+` | Inside float | Expand type one level |
| `-` | Inside float | Collapse type one level |
| `q` / `Esc` | Inside float | Close float, return focus to source |

The float also closes automatically when you move the cursor in the source buffer.

The footer at the bottom of the float shows the current verbosity depth and available actions:

```
depth: 0  [+] expand  [-] collapse  [q] close
```

When maximum expansion is reached, the footer shows `[max]` instead of `[+] expand`.

## How it works

The plugin sends `typescript.tsserverRequest` commands to vtsls using the `workspace/executeCommand` LSP method. It passes the `verbosityLevel` parameter (introduced in TypeScript 5.9) to tsserver's `quickinfo` command, which controls how deeply type aliases are expanded in the response.

1. Press `K` — sends a quickinfo request with `verbosityLevel: 0` (default)
2. Press `+` — increments verbosity and re-requests; the float updates in-place
3. Press `-` — decrements verbosity and re-requests
4. A generation counter ensures that if you press `K` again while a response is in-flight, the stale response from the previous session is discarded

When vtsls is not attached to the buffer (e.g., in a Lua or Python file) or when TypeScript < 5.9 is detected, the plugin falls back to the standard `vim.lsp.buf.hover()`.

## Health check

Run `:checkhealth ts_expand_hover` to verify your setup. It reports:

- NeoVim version (must be 0.10+)
- Whether vtsls is attached to the current buffer
- vtsls server version
- TypeScript version detected by vtsls

Open a TypeScript file before running the health check so vtsls has a chance to attach.

## Troubleshooting

**Hover shows the standard LSP float instead of the expandable one**

vtsls is not attached to the buffer. Check with `:checkhealth ts_expand_hover`. Make sure your LSP config starts vtsls for TypeScript files.

**Pressing + does nothing**

- The footer shows `[max]` — you've reached maximum expansion for this type
- TypeScript < 5.9 — vtsls doesn't support `verbosityLevel`; the plugin falls back to standard hover

**Float doesn't open at all**

- NeoVim < 0.10 — the plugin requires 0.10+ for the `footer` option in `nvim_open_win`
- `setup()` was never called — make sure your plugin manager calls `require("ts_expand_hover").setup()`

**K is already bound to something else**

Recommended: use a custom hover key to avoid mapping conflicts.

```lua
require("ts_expand_hover").setup({
  keymaps = { hover = "<leader>th" },
})
```

If you specifically want `K`, disable the global mapping and remap it only for
TypeScript buffers (see "Recommended binding strategy" above).

## Running tests

```sh
make test
```

Requires NeoVim and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Tests run headlessly with no live LSP dependency.

## License

MIT
