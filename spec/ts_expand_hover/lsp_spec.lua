local stub = require("luassert.stub")

-- Reload lsp module fresh for each test (compat shim is captured at load time).
local function fresh_lsp()
  package.loaded["ts_expand_hover.lsp"] = nil
  return require("ts_expand_hover.lsp")
end

-- Build a fake vtsls client that calls callback with the given args.
local function make_fake_client(err, result)
  return {
    request = function(self, method, params, callback, bufnr)
      callback(err, result, nil)
    end,
  }
end

-- Build a fake vtsls client that captures params and returns success.
local function make_capturing_client(capture_table)
  return {
    request = function(self, method, params, callback, bufnr)
      capture_table.method = method
      capture_table.params = params
      callback(nil, { body = { displayString = "type Foo = string", canIncreaseVerbosityLevel = true } }, nil)
    end,
  }
end

describe("lsp.request", function()
  local original_schedule
  local buf_hover_stub
  local get_clients_stub
  local buf_get_name_stub

  before_each(function()
    -- Make vim.schedule synchronous so COMP-02 fallback fires immediately.
    original_schedule = vim.schedule
    vim.schedule = function(f) f() end

    -- Stub vim.lsp.buf.hover so we can assert it was or wasn't called.
    buf_hover_stub = stub(vim.lsp.buf, "hover")

    -- Stub nvim_buf_get_name so lsp.lua doesn't hit a real buffer.
    buf_get_name_stub = stub(vim.api, "nvim_buf_get_name").returns("/fake/test.ts")
  end)

  after_each(function()
    vim.schedule = original_schedule
    buf_hover_stub:revert()
    buf_get_name_stub:revert()

    -- Revert get_clients stub if it was set during the test.
    if get_clients_stub then
      get_clients_stub:revert()
      get_clients_stub = nil
    end

    -- Evict the module so the compat shim re-evaluates on the next fresh_lsp().
    package.loaded["ts_expand_hover.lsp"] = nil
  end)

  -- ------------------------------------------------------------------ COMP-01

  it("calls vim.lsp.buf.hover() when no supported client is attached (COMP-01)", function()
    get_clients_stub = stub(vim.lsp, "get_clients").returns({})
    local lsp = fresh_lsp()

    local cb_called = false
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = false },
      callback  = function() cb_called = true end,
    })

    assert.stub(buf_hover_stub).was.called()
    assert.is_false(cb_called)
  end)

  it("does not set state.requesting when falling back (COMP-01)", function()
    get_clients_stub = stub(vim.lsp, "get_clients").returns({})
    local lsp = fresh_lsp()

    local state = { requesting = false }
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = state,
      callback  = function() end,
    })

    assert.is_false(state.requesting)
  end)

  -- ------------------------------------------------------------------ COMP-02

  it("falls back to vim.lsp.buf.hover() when client returns error (COMP-02)", function()
    local fake_client = make_fake_client({ code = -32603 }, nil)
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local state = { requesting = false }
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = state,
      callback  = function() end,
    })

    assert.stub(buf_hover_stub).was.called()
    assert.is_false(state.requesting)
  end)

  it("falls back when result has no body (TypeScript < 5.9) (COMP-02)", function()
    local fake_client = make_fake_client(nil, {})
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local state = { requesting = false }
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = state,
      callback  = function() end,
    })

    assert.stub(buf_hover_stub).was.called()
    assert.is_false(state.requesting)
  end)

  it("falls back when result is nil (COMP-02)", function()
    local fake_client = make_fake_client(nil, nil)
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local state = { requesting = false }
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = state,
      callback  = function() end,
    })

    assert.stub(buf_hover_stub).was.called()
  end)

  -- ------------------------------------------------------------------ COMP-03

  it("uses vim.lsp.get_clients for client discovery (COMP-03)", function()
    local fake_client = make_fake_client(nil, {
      body = { displayString = "type Foo = string", canIncreaseVerbosityLevel = true },
    })
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = false },
      callback  = function() end,
    })

    assert.stub(get_clients_stub).was.called_with({ bufnr = 1, name = "vtsls" })
  end)

  -- ------------------------------------------------------------------ EXPN-07

  it("drops request silently when state.requesting is true (EXPN-07)", function()
    local request_called = false
    local fake_client = {
      request = function() request_called = true end,
    }
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local cb_called = false
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = true },
      callback  = function() cb_called = true end,
    })

    assert.is_false(request_called)
    assert.is_false(cb_called)
  end)

  it("sets state.requesting true during in-flight request (EXPN-07)", function()
    local requesting_mid_flight = nil

    local fake_client = {
      request = function(self, method, params, callback, bufnr)
        -- We are inside the client:request call — capture the state value.
        requesting_mid_flight = _G._test_state_ref and _G._test_state_ref.requesting
        callback(nil, { body = { displayString = "x", canIncreaseVerbosityLevel = false } }, nil)
      end,
    }
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local state = { requesting = false }
    _G._test_state_ref = state

    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = state,
      callback  = function() end,
    })

    _G._test_state_ref = nil

    assert.is_true(requesting_mid_flight)
    assert.is_false(state.requesting) -- reset after callback
  end)

  -- ------------------------------------------------------------------ Happy path

  it("calls callback with lines and can_expand on successful response", function()
    local body = { displayString = "type Foo = string", canIncreaseVerbosityLevel = true }
    local fake_client = make_fake_client(nil, { body = body })
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local received = nil
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = false },
      callback  = function(hover) received = hover end,
    })

    assert.same({ "```typescript", "type Foo = string", "```" }, received.lines)
    assert.is_true(received.can_expand)
  end)

  it("reports can_expand false when vtsls leaves canIncreaseVerbosityLevel out", function()
    local fake_client = make_fake_client(nil, { body = { displayString = "type Foo = string" } })
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local received = nil
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = false },
      callback  = function(hover) received = hover end,
    })

    assert.is_false(received.can_expand)
  end)

  it("sends correct params with coordinate conversion (row+1, col+1)", function()
    local captured = {}
    local fake_client = make_capturing_client(captured)
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    lsp.request({
      bufnr     = 1,
      row       = 5,
      col       = 10,
      verbosity = 2,
      state     = { requesting = false },
      callback  = function() end,
    })

    assert.equals("workspace/executeCommand", captured.method)
    assert.equals(6,           captured.params.arguments[2].line)
    assert.equals(11,          captured.params.arguments[2].offset)
    assert.equals(2,           captured.params.arguments[2].verbosityLevel)
    assert.equals("/fake/test.ts", captured.params.arguments[2].file)
  end)

  -- ------------------------------------------------------------------ vtsls quickinfo rendering

  describe("vtsls quickinfo rendering", function()

    -- Helper: send a request answered with the given quickinfo body and
    -- return the lines the callback receives.
    local function rendered_lines(body)
      local fake_client = make_fake_client(nil, { body = body })
      get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
      local lsp = fresh_lsp()

      local received = nil
      lsp.request({
        bufnr     = 1,
        row       = 0,
        col       = 0,
        verbosity = 0,
        state     = { requesting = false },
        callback  = function(hover) received = hover end,
      })
      return received.lines
    end

    it("renders fenced typescript code block (RNDR-01)", function()
      local lines = rendered_lines({ displayString = "type Foo = string" })
      assert.equals("```typescript",    lines[1])
      assert.equals("type Foo = string", lines[2])
      assert.equals("```",              lines[#lines])
    end)

    it("shows a placeholder when the body has no displayString", function()
      local lines = rendered_lines({ canIncreaseVerbosityLevel = true })
      assert.equals("(no type info)", lines[1])
    end)

    it("renders documentation text below type block (RNDR-02)", function()
      local lines = rendered_lines({
        displayString = "function greet(name: string): string",
        documentation = "Greets the given name.",
        tags          = {},
      })

      -- Type block
      assert.equals("```typescript", lines[1])
      assert.equals("function greet(name: string): string", lines[2])
      assert.equals("```",           lines[3])

      -- Blank separator then documentation
      assert.equals("",                     lines[4])
      assert.equals("Greets the given name.", lines[5])
    end)

    it("handles multi-line documentation (RNDR-02)", function()
      local lines = rendered_lines({
        displayString = "const x: number",
        documentation = "Line one.\nLine two.",
        tags          = {},
      })

      -- Fence block is 3 lines; blank sep at [4]
      assert.equals("Line one.", lines[5])
      assert.equals("Line two.", lines[6])
    end)

    it("skips documentation section when documentation is empty (RNDR-02)", function()
      local lines = rendered_lines({
        displayString = "const x: number",
        documentation = "",
        tags          = {},
      })

      -- Single-line type → fence is exactly 3 lines; no extras when docs empty
      assert.equals(3, #lines)
      assert.equals("```typescript",  lines[1])
      assert.equals("const x: number", lines[2])
      assert.equals("```",             lines[3])
    end)

    it("renders JSDoc tags below documentation (RNDR-03)", function()
      local lines = rendered_lines({
        displayString = "function greet(name: string): string",
        documentation = "Greets the given name.",
        tags = {
          { name = "param",   text = "name The name" },
          { name = "returns", text = "A greeting" },
        },
      })

      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("**@param** name The name",   1, true))
      assert.is_truthy(joined:find("**@returns** A greeting",    1, true))
    end)

    it("renders tags without documentation (RNDR-03)", function()
      local lines = rendered_lines({
        displayString = "function greet(name: string): string",
        documentation = "",
        tags = {
          { name = "deprecated", text = "Use hi() instead" },
        },
      })

      -- Fence block (3 lines), blank sep, tag line
      assert.equals("```typescript", lines[1])
      assert.equals("```",           lines[3])
      assert.equals("",              lines[4])
      assert.equals("**@deprecated** Use hi() instead", lines[5])
    end)

    it("handles SymbolDisplayPart arrays in documentation and tags (RNDR-03)", function()
      local lines = rendered_lines({
        displayString = "type X = string",
        documentation = { { kind = "text", text = "A desc." } },
        tags = {
          { name = "deprecated", text = { { kind = "text", text = "Use Y." } } },
        },
      })

      local joined = table.concat(lines, "\n")
      assert.is_truthy(joined:find("A desc.",             1, true))
      assert.is_truthy(joined:find("**@deprecated** Use Y.", 1, true))
    end)

    it("skips tags section when tags is empty (RNDR-03)", function()
      local lines = rendered_lines({
        displayString = "const x: number",
        documentation = "Some docs.",
        tags          = {},
      })

      -- Fence (3) + blank (1) + doc (1) = 5 total; no trailing blank for tags
      assert.equals(5, #lines)
      assert.equals("Some docs.", lines[5])
    end)

  end) -- vtsls quickinfo rendering

end)
