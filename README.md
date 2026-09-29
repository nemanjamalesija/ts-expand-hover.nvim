# ts-expand-hover.nvim

![ts-expand-hover demo](https://github.com/nemanjamalesija/ts-expand-hover.nvim/raw/main/assets/demo.gif)

Expandable TypeScript type inspection for NeoVim. Uses TypeScript's `verbosityLevel` hover API to let you progressively expand and collapse type aliases directly inside a hover float. Works with vtsls (TypeScript 5.9+) and with the TypeScript 7 language server (`tsc --lsp`, also known as tsgo).

## Features

- **Progressive type expansion** — press `+` to expand type aliases one level at a time, `-` to collapse
- **In-place float updates** — content updates without closing or repositioning the float
- **Treesitter highlighting** — TypeScript code fences are syntax-highlighted via treesitter markdown injection
- **Documentation and JSDoc** — documentation text and `@param`/`@returns`/`@example` tags rendered below the type block
- **Configurable keymaps and float** — override or disable any keymap; customize border, max width, max height
- **Graceful fallback** — falls back to `vim.lsp.buf.hover()` when no supported server is attached or the server cannot answer
- **Concurrent request guard** — rapid key presses are silently dropped; stale responses are discarded

## Requirements

- **NeoVim 0.10+**
- One TypeScript language server attached to your TypeScript buffers:
  - **[vtsls](https://github.com/yioneko/vtsls)** v0.2.9+ with **TypeScript 5.9+** (v0.3.0+ recommended — bundles TypeScript 5.9), or
  - **TypeScript 7** (`tsc --lsp`), the server [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) calls `tsc` (older versions call it `tsgo`). See [TypeScript 7 setup](#typescript-7-setup) — one capability is required.

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

## TypeScript 7 setup

The TypeScript 7 server tells the plugin whether a type can expand further only when the client declared the `experimental.hoverVerbosityLevel` capability. Without it, the float opens but `+` does nothing. Add the capability to your `tsc` LSP config (NeoVim 0.11+ shown):

```lua
vim.lsp.config("tsc", {
  capabilities = { experimental = { hoverVerbosityLevel = true } },
  -- Optional. The server cuts long types at 500 characters and shows
  -- "... N more ..." in their place. Raise the cap to see big types whole.
  settings = { ["js/ts"] = { maximumHoverLength = 5000 } },
})
vim.lsp.enable("tsc")
```

TypeScript flags this capability as experimental, so treat TypeScript 7 support as experimental too. `:checkhealth ts_expand_hover` reports whether the capability is declared.

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

Run `:checkhealth ts_expand_hover` to verify your setup: NeoVim version, which server is attached, its TypeScript version, and for the TypeScript 7 server whether the `experimental.hoverVerbosityLevel` capability is declared. Open a TypeScript file first so the server has a chance to attach.

<details>
<summary><strong>How it works</strong></summary>

Both servers take a `verbosityLevel` that controls how deeply type aliases are expanded, and answer whether the type can expand further.

- **vtsls** — the plugin sends `typescript.tsserverRequest` commands via `workspace/executeCommand`, passing `verbosityLevel` (TypeScript 5.9) to tsserver's `quickinfo` command. The answer carries `canIncreaseVerbosityLevel`.
- **TypeScript 7** — the plugin sends a plain `textDocument/hover` request with `verbosityLevel` on it. The answer is markdown plus `canIncreaseVerbosity`.

1. `K` — sends a request with `verbosityLevel: 0`
2. `+` — increments verbosity and re-requests; the float updates in-place
3. `-` — decrements verbosity and re-requests
4. A generation counter discards stale responses from prior hover sessions

When no supported server is attached, or the server answers with an error (TypeScript < 5.9 on vtsls included), the plugin falls back to `vim.lsp.buf.hover()`. When both servers are attached to a buffer, vtsls is used.

</details>

<details>
<summary><strong>Troubleshooting</strong></summary>

**Hover shows the standard LSP float** — no supported server is attached. Run `:checkhealth ts_expand_hover` and make sure your LSP config starts vtsls or the TypeScript 7 server (`tsc`) for TypeScript files.

**Pressing + does nothing** — the footer shows `[max]` (fully expanded), TypeScript < 5.9 is in use with vtsls, or the TypeScript 7 server was started without the `experimental.hoverVerbosityLevel` capability (see [TypeScript 7 setup](#typescript-7-setup)).

**Type ends with `... N more ...`** — the TypeScript 7 server cuts long types at `maximumHoverLength` (500 by default). Raise it in the server settings (see [TypeScript 7 setup](#typescript-7-setup)).

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
