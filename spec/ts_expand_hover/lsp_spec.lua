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

  it("calls vim.lsp.buf.hover() when no vtsls client is attached (COMP-01)", function()
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

  it("calls callback with body on successful response", function()
    local expected_body = { displayString = "type Foo = string", canIncreaseVerbosityLevel = true }
    local fake_client = make_fake_client(nil, { body = expected_body })
    get_clients_stub = stub(vim.lsp, "get_clients").returns({ fake_client })
    local lsp = fresh_lsp()

    local received_body = nil
    lsp.request({
      bufnr     = 1,
      row       = 0,
      col       = 0,
      verbosity = 0,
      state     = { requesting = false },
      callback  = function(body) received_body = body end,
    })

    assert.are.equal(expected_body, received_body)
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
end)
