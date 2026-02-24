--- Integration tests for expand/collapse logic wired in init.lua.
--- Tests boundary guards, generation counter, and source_pos capture.
--- Uses approach (b) from the plan: capture keymap callbacks from vim.keymap.set
--- and invoke them directly to test the full init -> lsp -> float pipeline.
---
--- Key design: the +/- keymap closures are registered once during _open (initial
--- float.show). Subsequent float.show calls use _update (in-place), which does
--- NOT re-register keymaps. Callbacks captured after hover() remain valid for
--- all subsequent expand/collapse calls.

local stub   = require("luassert.stub")
local config = require("ts_expand_hover.config")

-- Stubs table — populated in before_each, reverted in after_each.
local stubs = {}

-- Evict the full pipeline for isolation between tests.
local function fresh_init()
  package.loaded["ts_expand_hover"]       = nil
  package.loaded["ts_expand_hover.float"] = nil
  package.loaded["ts_expand_hover.lsp"]   = nil
  return require("ts_expand_hover")
end

-- ------------------------------------------------------------------ helpers

-- Scan vim.keymap.set stub calls and return the callback for a given key.
-- Searches in forward order and returns the first match.
local function find_keymap_cb(key)
  for _, c in ipairs(stubs.keymap_set.calls) do
    if c.vals[2] == key then
      return c.vals[3]  -- keymap.set(mode, key, fn, opts)
    end
  end
  return nil
end

-- ------------------------------------------------------------------ setup

describe("expand/collapse", function()

  before_each(function()
    -- Reset config to defaults before every test (float.lua calls config.get().float).
    config.setup(nil)

    -- Make vim.schedule synchronous so LSP callbacks fire immediately in tests.
    stubs.original_schedule = vim.schedule
    vim.schedule = function(f) f() end

    -- vim.api stubs — mirror float_spec.lua pattern.
    stubs.nvim_get_current_buf   = stub(vim.api, "nvim_get_current_buf").returns(10)
    stubs.nvim_win_get_cursor    = stub(vim.api, "nvim_win_get_cursor").returns({ 10, 5 })
    stubs.nvim_create_buf        = stub(vim.api, "nvim_create_buf").returns(42)
    stubs.nvim_open_win          = stub(vim.api, "nvim_open_win").returns(100)
    stubs.nvim_buf_set_lines     = stub(vim.api, "nvim_buf_set_lines")
    stubs.nvim_win_is_valid      = stub(vim.api, "nvim_win_is_valid").returns(true)
    stubs.nvim_buf_is_valid      = stub(vim.api, "nvim_buf_is_valid").returns(true)
    stubs.nvim_get_current_win   = stub(vim.api, "nvim_get_current_win").returns(99)
    stubs.nvim_win_get_config    = stub(vim.api, "nvim_win_get_config").returns({
      relative   = "cursor",
      width      = 80,
      height     = 10,
      footer_pos = "left",
    })
    stubs.nvim_win_set_config    = stub(vim.api, "nvim_win_set_config")
    stubs.nvim_win_close         = stub(vim.api, "nvim_win_close")
    stubs.nvim_set_current_win   = stub(vim.api, "nvim_set_current_win")
    stubs.nvim_create_augroup    = stub(vim.api, "nvim_create_augroup").returns(1)
    stubs.nvim_create_autocmd    = stub(vim.api, "nvim_create_autocmd").returns(1)
    stubs.nvim_del_augroup_by_name = stub(vim.api, "nvim_del_augroup_by_name")
    stubs.nvim_win_set_cursor    = stub(vim.api, "nvim_win_set_cursor")
    stubs.nvim_buf_get_name      = stub(vim.api, "nvim_buf_get_name").returns("/fake/test.ts")
    stubs.nvim_set_option_value  = stub(vim.api, "nvim_set_option_value")
    stubs.nvim_buf_set_option    = stub(vim.api, "nvim_buf_set_option")
    stubs.nvim_win_set_option    = stub(vim.api, "nvim_win_set_option")

    stubs.strdisplaywidth = stub(vim.fn, "strdisplaywidth").invokes(function(s)
      return s ~= nil and #s or 0
    end)

    stubs.keymap_set = stub(vim.keymap, "set")

    -- Stub lsp.buf.hover for COMP-01/COMP-02 fallback paths.
    stubs.buf_hover = stub(vim.lsp.buf, "hover")

    -- Stub treesitter to prevent real parser calls.
    vim.treesitter = vim.treesitter or {}
    stubs.treesitter_start = stub(vim.treesitter, "start")

    -- Default LSP client: success with expandable body (verbosity 0).
    local expandable_body = {
      displayString             = "type Foo = string",
      canIncreaseVerbosityLevel = true,
    }
    local fake_client = {
      request = function(self, method, params, callback, bufnr)
        callback(nil, { body = expandable_body }, nil)
      end,
    }
    stubs.get_clients = stub(vim.lsp, "get_clients").returns({ fake_client })
  end)

  after_each(function()
    vim.schedule = stubs.original_schedule

    -- Revert all stubs.
    for k, s in pairs(stubs) do
      if k ~= "original_schedule" and type(s) == "table" and s.revert then
        s:revert()
      end
    end
    stubs = {}

    -- Evict modules so next test gets a clean slate.
    package.loaded["ts_expand_hover"]       = nil
    package.loaded["ts_expand_hover.float"] = nil
    package.loaded["ts_expand_hover.lsp"]   = nil
  end)

  -- ================================================================ source_pos

  describe("source_pos capture", function()

    it("M.hover() captures source_pos from cursor position", function()
      local init = fresh_init()
      init.hover()

      -- cursor returns { 10, 5 }; row is converted to 0-indexed (10-1 = 9).
      local state = init.get_state()
      assert.same({ 9, 5 }, state.source_pos)
    end)

    it("expand uses captured source_pos, not current cursor", function()
      -- Track what line/offset the expand lsp request receives.
      local captured_row, captured_col

      stubs.get_clients:revert()
      local call_count = 0
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        local body = { displayString = "x", canIncreaseVerbosityLevel = true }
        return {{
          request = function(self, method, params, callback, bufnr)
            call_count = call_count + 1
            if call_count >= 2 then
              -- Second+ call is from expand — capture the tsserver coordinates.
              captured_row = params.arguments[2].line
              captured_col = params.arguments[2].offset
            end
            callback(nil, { body = body }, nil)
          end,
        }}
      end)

      local init = fresh_init()
      -- hover() fires call_count=1; captures source_pos = { 9, 5 }.
      init.hover()

      -- Capture the + callback registered during hover() (registered in _open).
      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb, "expected + keymap to be registered after hover()")

      -- Simulate cursor moving to a completely different position.
      stubs.nvim_win_get_cursor:revert()
      stubs.nvim_win_get_cursor = stub(vim.api, "nvim_win_get_cursor").returns({ 99, 0 })

      -- Trigger expand — should use source_pos { 9, 5 }, NOT the current cursor.
      expand_cb()

      -- tsserver line = source_pos[1]+1 = 9+1 = 10; offset = source_pos[2]+1 = 5+1 = 6.
      assert.equals(10, captured_row)
      assert.equals(6,  captured_col)
    end)

  end) -- source_pos capture

  -- ================================================================ boundary guards

  describe("boundary guards", function()

    it("expand is no-op when can_expand is false (EXPN-05)", function()
      local init = fresh_init()
      init.hover()

      -- Manually set can_expand to false (simulates max-depth response).
      local state = init.get_state()
      state.can_expand = false

      -- Replace client to track whether a new request fires.
      local second_request_fired = false
      stubs.get_clients:revert()
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        return {{
          request = function()
            second_request_fired = true
          end,
        }}
      end)

      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb, "expected + keymap to be registered")
      expand_cb()

      assert.is_false(second_request_fired)
      -- verbosity must not change.
      assert.equals(0, state.verbosity)
    end)

    it("collapse is no-op when verbosity is 0 (EXPN-06)", function()
      local init = fresh_init()
      init.hover()

      local state = init.get_state()
      assert.equals(0, state.verbosity)

      -- Replace client to track whether a new request fires.
      local second_request_fired = false
      stubs.get_clients:revert()
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        return {{
          request = function()
            second_request_fired = true
          end,
        }}
      end)

      local collapse_cb = find_keymap_cb("-")
      assert.is_not_nil(collapse_cb, "expected - keymap to be registered")
      collapse_cb()

      assert.is_false(second_request_fired)
      assert.equals(0, state.verbosity)
    end)

  end) -- boundary guards

  -- ================================================================ expand mechanics

  describe("expand mechanics (EXPN-01)", function()

    it("expand increments verbosity and fires lsp.request", function()
      local expand_request_called = false
      local verbosity_at_expand

      stubs.get_clients:revert()
      local call_count = 0
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        local body = { displayString = "x", canIncreaseVerbosityLevel = true }
        return {{
          request = function(self, method, params, callback, bufnr)
            call_count = call_count + 1
            if call_count >= 2 then
              expand_request_called = true
              verbosity_at_expand = params.arguments[2].verbosityLevel
            end
            callback(nil, { body = body }, nil)
          end,
        }}
      end)

      local init = fresh_init()
      init.hover()

      local state = init.get_state()
      -- Capture expand callback registered during initial hover().
      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb)

      -- Trigger expand.
      expand_cb()

      assert.is_true(expand_request_called)
      assert.equals(1, verbosity_at_expand)
      assert.equals(1, state.verbosity)
    end)

  end) -- expand mechanics

  -- ================================================================ collapse mechanics

  describe("collapse mechanics (EXPN-02)", function()

    it("collapse decrements verbosity and fires lsp.request", function()
      local collapse_request_called = false
      local verbosity_at_collapse

      stubs.get_clients:revert()
      local call_count = 0
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        local body = { displayString = "x", canIncreaseVerbosityLevel = true }
        return {{
          request = function(self, method, params, callback, bufnr)
            call_count = call_count + 1
            if call_count == 3 then
              -- Third call: the collapse request.
              collapse_request_called = true
              verbosity_at_collapse = params.arguments[2].verbosityLevel
            end
            callback(nil, { body = body }, nil)
          end,
        }}
      end)

      local init = fresh_init()
      -- Call 1: initial hover (verbosity 0).
      init.hover()

      local state = init.get_state()

      -- Capture callbacks registered during initial hover().
      -- Both + and - are registered in _open (not re-registered in _update).
      local expand_cb  = find_keymap_cb("+")
      local collapse_cb = find_keymap_cb("-")
      assert.is_not_nil(expand_cb)
      assert.is_not_nil(collapse_cb)

      -- Call 2: expand (verbosity 0 -> 1).
      expand_cb()
      assert.equals(1, state.verbosity)

      -- Call 3: collapse (verbosity 1 -> 0).
      collapse_cb()

      assert.is_true(collapse_request_called)
      assert.equals(0, verbosity_at_collapse)
      assert.equals(0, state.verbosity)
    end)

  end) -- collapse mechanics

  -- ================================================================ generation counter

  describe("generation counter (EXPN-03)", function()

    it("generation counter increments on each expand", function()
      stubs.get_clients:revert()
      local body = { displayString = "x", canIncreaseVerbosityLevel = true }
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        return {{
          request = function(self, method, params, callback, bufnr)
            callback(nil, { body = body }, nil)
          end,
        }}
      end)

      local init = fresh_init()
      init.hover()

      local state = init.get_state()
      assert.equals(0, state.generation)

      -- Both + callbacks are the same closure — registered once during _open.
      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb)

      expand_cb()
      assert.equals(1, state.generation)

      -- The same closure still works for the second expand.
      expand_cb()
      assert.equals(2, state.generation)
    end)

    it("stale response is discarded when generation has advanced", function()
      -- The expand client holds the callback without firing it,
      -- simulating an in-flight request that arrives after a newer one.
      local held_callback = nil
      local float_show_calls = 0

      stubs.get_clients:revert()
      local first_call = true
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        local body = { displayString = "x", canIncreaseVerbosityLevel = true }
        return {{
          request = function(self, method, params, callback, bufnr)
            if first_call then
              first_call = false
              callback(nil, { body = body }, nil)
            else
              -- Hold the callback so we can fire it manually later.
              held_callback = callback
            end
          end,
        }}
      end)

      local init = fresh_init()
      init.hover()

      local state = init.get_state()

      -- Patch float.show to count actual calls.
      local float_module = require("ts_expand_hover.float")
      local original_show = float_module.show
      float_module.show = function(...)
        float_show_calls = float_show_calls + 1
        original_show(...)
      end

      -- Trigger expand — request is held (state.requesting becomes true).
      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb)
      expand_cb()
      assert.equals(1, state.generation)
      assert.is_not_nil(held_callback)

      -- Clear requesting so we can manually manipulate state.
      state.requesting = false

      -- Manually advance generation to simulate a newer request completing first.
      state.generation = state.generation + 1  -- now generation = 2

      -- Record current show call count before firing the stale callback.
      local show_calls_before = float_show_calls

      -- Fire the stale callback — the generation guard should discard it.
      -- The lsp module calls `opts.state.requesting = false` then `opts.callback(result.body)`.
      -- We simulate the full callback path: state.requesting is already false; fire directly.
      -- The held_callback is the raw `client:request` callback from lsp.lua, which has
      -- the form: function(err, result, ctx). It resets requesting and calls opts.callback.
      held_callback(nil, { body = { displayString = "stale", canIncreaseVerbosityLevel = true } }, nil)

      -- float.show should NOT have been called for the stale response.
      assert.equals(show_calls_before, float_show_calls)

      float_module.show = original_show
    end)

  end) -- generation counter

  -- ================================================================ footer state integration

  describe("footer state integration (EXPN-08)", function()

    it("float.show is called with max-depth body after expanding to limit", function()
      local last_body_seen = nil
      local max_body = {
        displayString             = "type Foo = string",
        canIncreaseVerbosityLevel = false,  -- max depth reached
      }

      stubs.get_clients:revert()
      local first_call = true
      stubs.get_clients = stub(vim.lsp, "get_clients").invokes(function()
        return {{
          request = function(self, method, params, callback, bufnr)
            local body
            if first_call then
              first_call = false
              body = { displayString = "x", canIncreaseVerbosityLevel = true }
            else
              body = max_body
            end
            callback(nil, { body = body }, nil)
          end,
        }}
      end)

      local init = fresh_init()
      init.hover()

      -- Patch float.show to capture the body argument.
      local float_module = require("ts_expand_hover.float")
      local original_show = float_module.show
      float_module.show = function(body, ...)
        last_body_seen = body
        original_show(body, ...)
      end

      local expand_cb = find_keymap_cb("+")
      assert.is_not_nil(expand_cb)
      expand_cb()

      -- The body passed to float.show on expand should have canIncreaseVerbosityLevel = false.
      assert.is_not_nil(last_body_seen)
      assert.is_false(last_body_seen.canIncreaseVerbosityLevel)

      float_module.show = original_show
    end)

  end) -- footer state integration

end)
