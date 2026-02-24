local stub   = require("luassert.stub")
local spy    = require("luassert.spy")
local config = require("ts_expand_hover.config")

-- Evict float module so each test gets a fresh require.
local function fresh_float()
  package.loaded["ts_expand_hover.float"] = nil
  return require("ts_expand_hover.float")
end

-- Build a minimal state table for show() / close() tests.
local function new_state(overrides)
  local s = {
    float_winid  = nil,
    float_bufnr  = nil,
    source_bufnr = 1,
    source_winid = nil,
    verbosity    = 0,
    requesting   = false,
  }
  if overrides then
    for k, v in pairs(overrides) do s[k] = v end
  end
  return s
end

local SUCCESS_BODY = { displayString = "type Foo = string", canIncreaseVerbosityLevel = true }

-- Stubs table — populated in before_each, reverted in after_each.
local stubs = {}

describe("float", function()

  before_each(function()
    -- Reset config to defaults before every test.
    config.setup(nil)

    -- Stub individual vim.api functions instead of using mock(vim.api, true).
    -- This avoids deep-mock interference with vim internals.
    stubs.nvim_create_buf       = stub(vim.api, "nvim_create_buf").returns(42)
    stubs.nvim_open_win         = stub(vim.api, "nvim_open_win").returns(100)
    stubs.nvim_buf_set_lines    = stub(vim.api, "nvim_buf_set_lines")
    stubs.nvim_win_is_valid     = stub(vim.api, "nvim_win_is_valid").returns(true)
    stubs.nvim_buf_is_valid     = stub(vim.api, "nvim_buf_is_valid").returns(true)
    stubs.nvim_get_current_win  = stub(vim.api, "nvim_get_current_win").returns(99)
    stubs.nvim_win_get_config   = stub(vim.api, "nvim_win_get_config").returns({
      relative   = "cursor",
      width      = 80,
      height     = 10,
      footer_pos = "left",
    })
    stubs.nvim_win_set_config   = stub(vim.api, "nvim_win_set_config")
    stubs.nvim_win_close        = stub(vim.api, "nvim_win_close")
    stubs.nvim_set_current_win  = stub(vim.api, "nvim_set_current_win")
    stubs.nvim_create_augroup   = stub(vim.api, "nvim_create_augroup").returns(1)
    stubs.nvim_create_autocmd   = stub(vim.api, "nvim_create_autocmd").returns(1)
    stubs.nvim_del_augroup_by_name = stub(vim.api, "nvim_del_augroup_by_name")
    stubs.nvim_win_set_cursor      = stub(vim.api, "nvim_win_set_cursor")

    -- NeoVim 0.10+ uses nvim_set_option_value for vim.bo/vim.wo.
    -- Stub it so property assignments don't hit real API with fake buffer IDs.
    stubs.nvim_set_option_value = stub(vim.api, "nvim_set_option_value")
    -- Older NeoVim fallback for vim.bo/vim.wo.
    stubs.nvim_buf_set_option = stub(vim.api, "nvim_buf_set_option")
    stubs.nvim_win_set_option = stub(vim.api, "nvim_win_set_option")

    -- strdisplaywidth: return byte length (headless-safe, avoids null char issues).
    stubs.strdisplaywidth = stub(vim.fn, "strdisplaywidth").invokes(function(s)
      return s ~= nil and #s or 0
    end)

    -- Capture keymap registrations without registering them.
    stubs.keymap_set = stub(vim.keymap, "set")

    -- Stub treesitter.start to prevent real parser calls in headless test mode.
    vim.treesitter = vim.treesitter or {}
    stubs.treesitter_start = stub(vim.treesitter, "start")
  end)

  after_each(function()
    -- Revert all stubs.
    for _, s in pairs(stubs) do
      s:revert()
    end
    stubs = {}

    -- Evict float module to reset its require-time state.
    package.loaded["ts_expand_hover.float"] = nil
  end)

  -- ============================================================ show (new float)

  describe("show (new float)", function()

    it("opens a focused float with enter=true (HOVR-01, HOVR-06)", function()
      local float = fresh_float()
      local state = new_state()

      float.show(SUCCESS_BODY, state)

      assert.stub(stubs.nvim_open_win).was.called()
      -- Second argument to nvim_open_win is `enter` — must be true.
      local call_args = stubs.nvim_open_win.calls[1]
      assert.is_true(call_args.vals[2])
      assert.equals(100, state.float_winid)
      assert.equals(42,  state.float_bufnr)
    end)

    it("uses configured border style (HOVR-05)", function()
      config.setup({ float = { border = "single" } })
      local float = fresh_float()
      local state = new_state()

      float.show(SUCCESS_BODY, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      assert.equals("single", win_cfg.border)
    end)

    it("respects max_width from config (HOVR-05)", function()
      config.setup({ float = { max_width = 40 } })
      local float = fresh_float()
      local state = new_state()

      -- Body with a very long displayString (100 chars).
      local long_body = { displayString = string.rep("x", 100) }
      float.show(long_body, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      assert.is_true(win_cfg.width <= 40)
    end)

    it("respects max_height from config (HOVR-05)", function()
      config.setup({ float = { max_height = 5 } })
      local float = fresh_float()
      local state = new_state()

      -- Body with 20 lines separated by newlines.
      local lines = {}
      for i = 1, 20 do lines[i] = "line " .. i end
      local tall_body = { displayString = table.concat(lines, "\n") }
      float.show(tall_body, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      assert.is_true(win_cfg.height <= 5)
    end)

    it("displays footer with depth and key hints (EXPN-04)", function()
      local float = fresh_float()
      local state = new_state({ verbosity = 0 })

      float.show(SUCCESS_BODY, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      -- footer is { { text, hl_group } }
      local footer_text = win_cfg.footer[1][1]
      assert.is_truthy(footer_text:find("depth: 0"))
      -- At verbosity 0 with canIncreaseVerbosityLevel=true: expand shows [+] expand,
      -- collapse shows [-] (non-functional at_min state per EXPN-06).
      assert.is_truthy(footer_text:find("%[%+%] expand"))
      assert.is_truthy(footer_text:find("%[%-%]"))
      assert.is_truthy(footer_text:find("%[q%] close"))
    end)

    it("footer reflects current verbosity level (EXPN-04)", function()
      local float = fresh_float()
      local state = new_state({ verbosity = 3 })

      float.show(SUCCESS_BODY, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      local footer_text = win_cfg.footer[1][1]
      assert.is_truthy(footer_text:find("depth: 3"))
    end)

    it("footer shows [max] when canIncreaseVerbosityLevel is false (EXPN-05)", function()
      local float = fresh_float()
      local state = new_state({ verbosity = 2 })
      local max_body = { displayString = "type Foo = string", canIncreaseVerbosityLevel = false }

      float.show(max_body, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      local footer_text = win_cfg.footer[1][1]
      assert.is_truthy(footer_text:find("%[max%]"))
      assert.is_falsy(footer_text:find("%[%+%] expand"))
    end)

    it("footer shows [-] without collapse label at depth 0 (EXPN-06)", function()
      local float = fresh_float()
      -- verbosity = 0 means at_min = true → collapse hint is just [-]
      local state = new_state({ verbosity = 0 })

      float.show(SUCCESS_BODY, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      local footer_text = win_cfg.footer[1][1]
      -- [-] is present (visible but non-functional at min depth)
      assert.is_truthy(footer_text:find("%[%-%]"))
      -- [-] collapse should NOT be present at depth 0
      assert.is_falsy(footer_text:find("%[%-%] collapse"))
    end)

    it("footer shows [-] collapse when verbosity > 0 (EXPN-06)", function()
      local float = fresh_float()
      local state = new_state({ verbosity = 1 })

      float.show(SUCCESS_BODY, state)

      local call_args = stubs.nvim_open_win.calls[1]
      local win_cfg = call_args.vals[3]
      local footer_text = win_cfg.footer[1][1]
      assert.is_truthy(footer_text:find("%[%-%] collapse"))
    end)

    it("registers q and Esc keymaps on float buffer (HOVR-04)", function()
      local float = fresh_float()
      local state = new_state()

      float.show(SUCCESS_BODY, state)

      -- keymap.set should have been called at least twice.
      local calls = stubs.keymap_set.calls
      assert.is_true(#calls >= 2)

      -- Collect registered keys and their opts.
      local registered = {}
      for _, c in ipairs(calls) do
        -- keymap.set(mode, key, fn, opts)
        registered[c.vals[2]] = c.vals[4] or {}
      end

      -- Both q and <Esc> must be registered with buffer = 42 (fake buf).
      assert.is_not_nil(registered["q"],     "expected q keymap to be registered")
      assert.equals(42, registered["q"].buffer)
      assert.is_not_nil(registered["<Esc>"], "expected <Esc> keymap to be registered")
      assert.equals(42, registered["<Esc>"].buffer)
    end)

    it("registers + and - keymaps when callbacks provided (EXPN-01, EXPN-02)", function()
      local float = fresh_float()
      local state = new_state()
      local expand_cb  = function() end
      local collapse_cb = function() end

      float.show(SUCCESS_BODY, state, expand_cb, collapse_cb)

      local registered = {}
      for _, c in ipairs(stubs.keymap_set.calls) do
        registered[c.vals[2]] = c.vals[4] or {}
      end

      assert.is_not_nil(registered["+"], "expected + keymap to be registered")
      assert.equals(42, registered["+"].buffer)
      assert.is_not_nil(registered["-"], "expected - keymap to be registered")
      assert.equals(42, registered["-"].buffer)
      assert.is_not_nil(registered["<kPlus>"], "expected <kPlus> keymap to be registered")
      assert.equals(42, registered["<kPlus>"].buffer)
      assert.is_not_nil(registered["<kMinus>"], "expected <kMinus> keymap to be registered")
      assert.equals(42, registered["<kMinus>"].buffer)
    end)

    it("does not register + and - keymaps when callbacks are nil", function()
      local float = fresh_float()
      local state = new_state()

      -- No callbacks — only q and <Esc> should be registered.
      float.show(SUCCESS_BODY, state)

      local registered = {}
      for _, c in ipairs(stubs.keymap_set.calls) do
        registered[c.vals[2]] = true
      end

      assert.is_not_nil(registered["q"])
      assert.is_not_nil(registered["<Esc>"])
      assert.is_nil(registered["+"], "expected + keymap NOT to be registered without callback")
      assert.is_nil(registered["-"], "expected - keymap NOT to be registered without callback")
    end)

    it("applies treesitter markdown highlighting after content write (HOVR-02)", function()
      local float = fresh_float()
      local state = new_state()

      float.show(SUCCESS_BODY, state)

      -- treesitter.start is called via pcall inside _apply_treesitter.
      -- The stub captures the pcall-wrapped call.
      assert.stub(stubs.treesitter_start).was.called()
      -- Called with the float buffer and "markdown" parser.
      local call_args = stubs.treesitter_start.calls[1]
      assert.equals(42, call_args.vals[1])
      assert.equals("markdown", call_args.vals[2])
    end)

    it("writes fenced typescript code block to buffer (HOVR-02)", function()
      local float = fresh_float()
      local state = new_state()

      float.show(SUCCESS_BODY, state)

      local set_lines_call = stubs.nvim_buf_set_lines.calls[1]
      -- 5th arg is the lines table: bufnr, start, end, strict_indexing, lines
      local lines = set_lines_call.vals[5]
      assert.equals("```typescript", lines[1])
      assert.equals("type Foo = string", lines[2])
      assert.equals("```", lines[#lines])
    end)

  end) -- show (new float)

  -- ============================================================ show (in-place update)

  describe("show (in-place update)", function()

    it("updates existing float in-place without closing (HOVR-01)", function()
      local float = fresh_float()
      -- Simulate an already-open float.
      local state = new_state({ float_winid = 100, float_bufnr = 42 })

      stubs.nvim_win_is_valid:revert()
      stubs.nvim_win_is_valid = stub(vim.api, "nvim_win_is_valid").returns(true)
      stubs.nvim_buf_is_valid:revert()
      stubs.nvim_buf_is_valid = stub(vim.api, "nvim_buf_is_valid").returns(true)

      float.show({ displayString = "type Bar = number" }, state)

      -- No new window should be opened.
      assert.stub(stubs.nvim_open_win).was_not.called()
      -- Buffer content should be updated.
      assert.stub(stubs.nvim_buf_set_lines).was.called()
      -- Window config should be updated.
      assert.stub(stubs.nvim_win_set_config).was.called()
    end)

    it("resets scroll to top on in-place update (EXPN-03)", function()
      local float = fresh_float()
      -- Simulate an already-open float with winid=100.
      local state = new_state({ float_winid = 100, float_bufnr = 42 })

      stubs.nvim_win_is_valid:revert()
      stubs.nvim_win_is_valid = stub(vim.api, "nvim_win_is_valid").returns(true)
      stubs.nvim_buf_is_valid:revert()
      stubs.nvim_buf_is_valid = stub(vim.api, "nvim_buf_is_valid").returns(true)

      float.show({ displayString = "type Bar = number" }, state)

      -- nvim_win_set_cursor should be called to reset scroll to row 1, col 0.
      assert.stub(stubs.nvim_win_set_cursor).was.called()
      local cursor_call = stubs.nvim_win_set_cursor.calls[1]
      assert.equals(100, cursor_call.vals[1])
      assert.same({ 1, 0 }, cursor_call.vals[2])
    end)

  end) -- show (in-place update)

  -- ============================================================ close

  describe("close", function()

    it("closes float window and restores source focus (HOVR-04)", function()
      local float = fresh_float()
      local state = new_state({
        float_winid  = 100,
        float_bufnr  = 42,
        source_winid = 99,
      })

      float.close(state)

      assert.stub(stubs.nvim_win_close).was.called_with(100, true)
      assert.stub(stubs.nvim_set_current_win).was.called_with(99)
      assert.is_nil(state.float_winid)
      assert.is_nil(state.float_bufnr)
    end)

    it("nils state handles before closing to prevent re-entrant close", function()
      local float = fresh_float()
      local state = new_state({
        float_winid  = 100,
        source_winid = 99,
      })

      float.close(state)

      assert.is_nil(state.float_winid)
      assert.is_nil(state.source_winid)
    end)

  end) -- close

  -- ============================================================ auto-close (HOVR-03)

  describe("auto-close (HOVR-03)", function()

    it("registers CursorMoved autocmd on source buffer (HOVR-03)", function()
      local float = fresh_float()
      local state = new_state({ source_bufnr = 7 })

      float.show(SUCCESS_BODY, state)

      -- nvim_create_augroup should be called with a name containing the window ID.
      assert.stub(stubs.nvim_create_augroup).was.called()
      local augroup_call = stubs.nvim_create_augroup.calls[1]
      assert.is_truthy(augroup_call.vals[1]:find("ts_expand_hover_"))

      -- nvim_create_autocmd must be called with CursorMoved and source buffer.
      assert.stub(stubs.nvim_create_autocmd).was.called()
      local autocmd_call = stubs.nvim_create_autocmd.calls[1]
      local events = autocmd_call.vals[1]

      -- events is a table: { "CursorMoved", "BufLeave" }
      local has_cursor_moved = false
      for _, e in ipairs(events) do
        if e == "CursorMoved" then has_cursor_moved = true end
      end
      assert.is_true(has_cursor_moved)

      local autocmd_opts = autocmd_call.vals[2]
      assert.equals(7, autocmd_opts.buffer)
    end)

    it("also registers BufLeave autocmd on source buffer (HOVR-03)", function()
      local float = fresh_float()
      local state = new_state({ source_bufnr = 7 })

      float.show(SUCCESS_BODY, state)

      assert.stub(stubs.nvim_create_autocmd).was.called()
      local autocmd_call = stubs.nvim_create_autocmd.calls[1]
      local events = autocmd_call.vals[1]

      local has_buf_leave = false
      for _, e in ipairs(events) do
        if e == "BufLeave" then has_buf_leave = true end
      end
      assert.is_true(has_buf_leave)
    end)

  end) -- auto-close

  -- ============================================================ edge cases

  describe("edge cases", function()

    it("handles nil body gracefully", function()
      local float = fresh_float()
      local state = new_state()

      assert.has_no.errors(function()
        float.show(nil, state)
      end)

      assert.stub(stubs.nvim_buf_set_lines).was.called()
      local set_lines_call = stubs.nvim_buf_set_lines.calls[1]
      -- 4th arg is the lines table (bufnr, start, end, strict_indexing, lines)
      local lines = set_lines_call.vals[5]
      assert.equals("(no type info)", lines[1])
    end)

    it("handles body with no displayString", function()
      local float = fresh_float()
      local state = new_state()

      assert.has_no.errors(function()
        float.show({ canIncreaseVerbosityLevel = true }, state)
      end)

      assert.stub(stubs.nvim_buf_set_lines).was.called()
      local set_lines_call = stubs.nvim_buf_set_lines.calls[1]
      local lines = set_lines_call.vals[5]
      assert.equals("(no type info)", lines[1])
    end)

  end) -- edge cases

  -- ============================================================ content rendering

  describe("content rendering", function()

    -- Helper: run show() and return the lines written to the buffer.
    local function shown_lines(body)
      local float = fresh_float()
      local state = new_state()
      float.show(body, state)
      return stubs.nvim_buf_set_lines.calls[1].vals[5]
    end

    -- RNDR-01 ------------------------------------------------------------

    it("renders fenced typescript code block (RNDR-01)", function()
      local lines = shown_lines(SUCCESS_BODY)
      assert.equals("```typescript",    lines[1])
      assert.equals("type Foo = string", lines[2])
      assert.equals("```",              lines[#lines])
    end)

    -- RNDR-02 ------------------------------------------------------------

    it("renders documentation text below type block (RNDR-02)", function()
      local body = {
        displayString = "function greet(name: string): string",
        documentation = "Greets the given name.",
        tags          = {},
      }
      local lines = shown_lines(body)

      -- Type block
      assert.equals("```typescript", lines[1])
      assert.equals("function greet(name: string): string", lines[2])
      assert.equals("```",           lines[3])

      -- Blank separator then documentation
      assert.equals("",                     lines[4])
      assert.equals("Greets the given name.", lines[5])
    end)

    it("handles multi-line documentation (RNDR-02)", function()
      local body = {
        displayString = "const x: number",
        documentation = "Line one.\nLine two.",
        tags          = {},
      }
      local lines = shown_lines(body)

      -- Fence block is 3 lines; blank sep at [4]
      assert.equals("Line one.", lines[5])
      assert.equals("Line two.", lines[6])
    end)

    it("skips documentation section when documentation is empty (RNDR-02)", function()
      local body = {
        displayString = "const x: number",
        documentation = "",
        tags          = {},
      }
      local lines = shown_lines(body)

      -- Single-line type → fence is exactly 3 lines; no extras when docs empty
      assert.equals(3, #lines)
      assert.equals("```typescript",  lines[1])
      assert.equals("const x: number", lines[2])
      assert.equals("```",             lines[3])
    end)

    -- RNDR-03 ------------------------------------------------------------

    it("renders JSDoc tags below documentation (RNDR-03)", function()
      local body = {
        displayString = "function greet(name: string): string",
        documentation = "Greets the given name.",
        tags = {
          { name = "param",   text = "name The name" },
          { name = "returns", text = "A greeting" },
        },
      }
      local lines = shown_lines(body)

      -- Check tag lines exist somewhere in the output
      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("**@param** name The name",   1, true))
      assert.is_truthy(joined:find("**@returns** A greeting",    1, true))
    end)

    it("renders tags without documentation (RNDR-03)", function()
      local body = {
        displayString = "function greet(name: string): string",
        documentation = "",
        tags = {
          { name = "deprecated", text = "Use hi() instead" },
        },
      }
      local lines = shown_lines(body)

      -- Fence block (3 lines), blank sep, tag line
      assert.equals("```typescript", lines[1])
      assert.equals("```",           lines[3])
      assert.equals("",              lines[4])
      assert.equals("**@deprecated** Use hi() instead", lines[5])
    end)

    it("handles SymbolDisplayPart arrays in documentation and tags (RNDR-03)", function()
      local body = {
        displayString = "type X = string",
        documentation = { { kind = "text", text = "A desc." } },
        tags = {
          { name = "deprecated", text = { { kind = "text", text = "Use Y." } } },
        },
      }
      local lines = shown_lines(body)

      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("A desc.",             1, true))
      assert.is_truthy(joined:find("**@deprecated** Use Y.", 1, true))
    end)

    it("skips tags section when tags is empty (RNDR-03)", function()
      local body = {
        displayString = "const x: number",
        documentation = "Some docs.",
        tags          = {},
      }
      local lines = shown_lines(body)

      -- Fence (3) + blank (1) + doc (1) = 5 total; no trailing blank for tags
      assert.equals(5, #lines)
      assert.equals("Some docs.", lines[5])
    end)

  end) -- content rendering

end)
