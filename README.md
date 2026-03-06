# ts-expand-hover.nvim

![ts-expand-hover demo](https://github.com/nemanjamalesija/ts-expand-hover.nvim/raw/main/assets/demo.gif)

Expandable TypeScript type inspection for NeoVim. Uses TypeScript 5.9's `verbosityLevel` API to let you progressively expand and collapse type aliases directly inside a hover float.

## Features

- **Progressive type expansion** — press `+` to expand type aliases one level at a time, `-` to collapse
- **In-place float updates** — content updates without closing or repositioning the float
- **Treesitter highlighting** — TypeScript code fences are syntax-highlighted via treesitter markdown injection
- **Documentation and JSDoc** — documentation text and `@param`/`@returns`/`@example` tags rendered below the type block
- **Configurable keymaps and float** — override or disable any keymap; customize border, max width, max height
- **Graceful fallback** — falls back to `vim.lsp.buf.hover()` when vtsls is not attached or TypeScript < 5.9
- **Concurrent request guard** — rapid key presses are silently dropped; stale responses are discarded

## Requirements

- **NeoVim 0.10+**
- **[vtsls](https://github.com/yioneko/vtsls)** v0.2.9+ (v0.3.0+ recommended — bundles TypeScript 5.9)
- **TypeScript 5.9+** (for `verbosityLevel` support in tsserver's quickinfo)

## Installation

```lua
-- lazy.nvim
{
  "nemanjamalesija/ts-expand-hover.nvim",
  ft = { "typescript", "typescriptreact" },
  opts = {
    keymaps = { hover = "<leader>th" },
  },
}
```

For other plugin managers, call `require("ts_expand_hover").setup()` after loading.

## Configuration

Calling `setup()` with no arguments uses all defaults:

```lua
require("ts_expand_hover").setup({
  keymaps = {
    hover    = "K",               -- normal mode key to open hover float
    expand   = "+",               -- expand type one level (inside float)
    collapse = "-",               -- collapse type one level (inside float)
    close    = { "q", "<Esc>" },  -- close float and return to source
  },
  float = {
    border     = "rounded",   -- "rounded", "single", "double", "none"
    max_width  = 80,
    max_height = 30,
  },
})
```

Set any keymap to `false` to prevent the plugin from registering it, so you can bind it yourself:

```lua
require("ts_expand_hover").setup({
  keymaps = { hover = false },
})

-- TypeScript-only mapping to avoid conflicts with other plugins that map K
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

## Keymaps

| Key | Scope | Action |
|-----|-------|--------|
| `K` | Normal mode (global) | Open hover float at cursor |
| `+` | Inside float | Expand type one level |
| `-` | Inside float | Collapse type one level |
| `q` / `Esc` | Inside float | Close float, return focus to source |

The float closes automatically when you move the cursor in the source buffer. The footer shows the current verbosity depth and available actions. When maximum expansion is reached, the footer shows `[max]`.

## Health check

Run `:checkhealth ts_expand_hover` to verify your setup (NeoVim version, vtsls attachment, TypeScript version). Open a TypeScript file first so vtsls has a chance to attach.

<details>
<summary><strong>How it works</strong></summary>

The plugin sends `typescript.tsserverRequest` commands to vtsls via `workspace/executeCommand`. It passes the `verbosityLevel` parameter (TypeScript 5.9) to tsserver's `quickinfo` command, controlling how deeply type aliases are expanded.

1. `K` — sends a quickinfo request with `verbosityLevel: 0`
2. `+` — increments verbosity and re-requests; the float updates in-place
3. `-` — decrements verbosity and re-requests
4. A generation counter discards stale responses from prior hover sessions

When vtsls is not attached or TypeScript < 5.9 is detected, the plugin falls back to `vim.lsp.buf.hover()`.

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

**Hover shows the standard LSP float** — vtsls is not attached. Run `:checkhealth ts_expand_hover` and make sure your LSP config starts vtsls for TypeScript files.

**Pressing + does nothing** — either the footer shows `[max]` (fully expanded), or TypeScript < 5.9 is in use.

**Float doesn't open** — NeoVim < 0.10 is required for the `footer` option in `nvim_open_win`. Also verify `setup()` was called.

**K is already bound** — use a custom hover key (e.g. `hover = "<leader>th"`) or disable the global mapping and remap per-filetype (see Configuration above).

</details>

## Running tests

```sh
make test
```

Requires NeoVim and [plenary.nvim](https://github.com/nvim-lua/plenary.nvim). Tests run headlessly with no live LSP dependency.

## License

MIT
