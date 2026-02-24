--- Float lifecycle module for ts-expand-hover.nvim.
--- Handles open, in-place update, auto-close autocmds, and buffer-local keymaps.

local M = {}

--- Flatten a SymbolDisplayPart[] array or plain string to a single string.
--- Returns the input unchanged when it is already a string.
--- Returns nil for any other type (nil, boolean, number).
---@param val string|table|nil SymbolDisplayPart[] or plain string
---@return string|nil
local function _flatten_display_parts(val)
  if type(val) == "string" then return val end
  if type(val) == "table" then
    local texts = {}
    for _, part in ipairs(val) do
      if part.text then texts[#texts + 1] = part.text end
    end
    return table.concat(texts)
  end
  return nil
end

--- Split body.displayString into content lines wrapped in a typescript fenced code block.
--- Appends documentation text (RNDR-02) and JSDoc tags (RNDR-03) when present.
---@param body table LSP response body with displayString field
---@return string[]
local function _build_lines(body)
  if not body or not body.displayString then
    return { "(no type info)" }
  end
  local content_lines = vim.split(body.displayString, "\n", { plain = true })
  local result = { "```typescript" }
  for _, line in ipairs(content_lines) do
    result[#result + 1] = line
  end
  result[#result + 1] = "```"

  -- Documentation text (RNDR-02)
  local doc = _flatten_display_parts(body.documentation)
  if doc and doc ~= "" then
    result[#result + 1] = ""
    for _, line in ipairs(vim.split(doc, "\n", { plain = true })) do
      result[#result + 1] = line
    end
  end

  -- JSDoc tags (RNDR-03)
  if body.tags and #body.tags > 0 then
    result[#result + 1] = ""
    for _, tag in ipairs(body.tags) do
      local text = _flatten_display_parts(tag.text)
      local tag_lines = vim.split(text or "", "\n", { plain = true })
      result[#result + 1] = string.format("**@%s** %s", tag.name, tag_lines[1] or "")
      for i = 2, #tag_lines do
        result[#result + 1] = tag_lines[i]
      end
    end
  end

  return result
end

--- Return display width for text.
---@param text string
---@return integer
local function _display_width(text)
  return vim.fn.strdisplaywidth(text)
end

--- Truncate text so display width is <= max_width.
---@param text string
---@param max_width integer
---@return string
local function _truncate_to_width(text, max_width)
  if max_width <= 0 then return "" end
  if _display_width(text) <= max_width then return text end
  local chars = vim.fn.strchars(text)
  while chars > 0 do
    local candidate = vim.fn.strcharpart(text, 0, chars)
    if _display_width(candidate) <= max_width then
      return candidate
    end
    chars = chars - 1
  end
  return ""
end

--- Build footer variants ordered from most to least descriptive.
---@param state table Session state with verbosity field
---@param body table|nil LSP response body with canIncreaseVerbosityLevel field
---@return string[]
local function _build_footer_variants(state, body)
  local can_expand = body and body.canIncreaseVerbosityLevel
  local at_min     = state.verbosity == 0

  local expand_full
  if can_expand then
    expand_full = "[+] expand"
  else
    expand_full = "[max]"
  end

  local collapse_full
  if at_min then
    collapse_full = "[-]"
  else
    collapse_full = "[-] collapse"
  end

  local full = string.format(
    "depth: %d  %s  %s  [q] close",
    state.verbosity,
    expand_full,
    collapse_full
  )
  local medium = string.format(
    "d:%d  %s  [-]  [q]",
    state.verbosity,
    can_expand and "[+]" or "[max]"
  )
  local minimal = string.format("d:%d", state.verbosity)
  return { full, medium, minimal }
end

--- Apply treesitter markdown highlighting to the given buffer.
--- Called after every content write. pcall guards against missing markdown parser.
---@param bufnr integer
local function _apply_treesitter(bufnr)
  pcall(vim.treesitter.start, bufnr, "markdown")
end

--- Return the maximum display width of a list of lines.
---@param lines string[]
---@return integer
local function _max_line_width(lines)
  local max = 1
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > max then
      max = w
    end
  end
  return max
end

--- Compute window width/height and the best footer variant for available width.
--- Prefers the most descriptive footer that fits while respecting max_width.
---@param lines string[]
---@param state table
---@param body table|nil
---@param cfg table
---@return integer width
---@return integer height
---@return string footer_text
local function _compute_layout(lines, state, body, cfg)
  local content_width = _max_line_width(lines)
  local max_width = math.max(1, cfg.max_width)
  local variants = _build_footer_variants(state, body)

  -- Default to minimal footer when only max-width constrained content fits.
  local chosen_footer = variants[#variants]
  local width = math.min(max_width, math.max(content_width, _display_width(chosen_footer)))

  for _, footer in ipairs(variants) do
    local needed_width = math.max(content_width, _display_width(footer))
    if needed_width <= max_width then
      chosen_footer = footer
      width = needed_width
      break
    end
  end

  if _display_width(chosen_footer) > width then
    chosen_footer = _truncate_to_width(chosen_footer, width)
  end

  local height = math.min(cfg.max_height, #lines)
  return width, height, chosen_footer
end

--- Open a new focused floating window with the given content.
---@param lines string[]
---@param footer_text string
---@param width integer
---@param height integer
---@param state table
---@param cfg table float config (border, max_width, max_height)
---@param on_expand function|nil callback for + keymap
---@param on_collapse function|nil callback for - keymap
---@return integer win, integer buf
local function _open(lines, footer_text, width, height, state, cfg, on_expand, on_collapse)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  _apply_treesitter(buf)

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "cursor",
    width      = width,
    height     = height,
    row        = 1,
    col        = 0,
    style      = "minimal",
    border     = cfg.border,
    focusable  = true,
    footer     = { { footer_text, "FloatFooter" } },
    footer_pos = "left",
  })

  vim.wo[win].wrap = false

  state.float_bufnr = buf
  state.float_winid = win

  return win, buf
end

--- Update an existing float in-place without closing and reopening.
--- Uses the read-then-write pattern to avoid dropping footer_pos (NeoVim #31992).
---@param lines string[]
---@param footer_text string
---@param width integer
---@param height integer
---@param state table
local function _update(lines, footer_text, width, height, state)
  local buf = state.float_bufnr
  local win = state.float_winid

  if not vim.api.nvim_win_is_valid(win) then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  _apply_treesitter(buf)

  -- Read existing config first so relative, footer_pos, etc. are preserved.
  local existing = vim.api.nvim_win_get_config(win)
  existing.width  = width
  existing.height = height
  existing.footer = { { footer_text, "FloatFooter" } }
  vim.api.nvim_win_set_config(win, existing)

  -- Reset scroll to top after content change.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
end

--- Register CursorMoved and BufLeave autocmds on the source buffer.
--- The autocmds auto-close the float when focus returns to the source buffer.
--- Guard prevents premature close when the float itself is focused (NeoVim #12923).
---@param winid integer float window ID
---@param source_bufnr integer source buffer number
---@param state table
local function _setup_close_autocmds(winid, source_bufnr, state)
  local augroup_name = "ts_expand_hover_" .. winid
  local augroup = vim.api.nvim_create_augroup(augroup_name, { clear = true })

  vim.api.nvim_create_autocmd({ "CursorMoved", "BufLeave" }, {
    group  = augroup,
    buffer = source_bufnr,
    callback = function()
      -- When enter=true, opening the float fires CursorMoved on the source
      -- buffer. Guard prevents the float from closing itself immediately.
      if vim.api.nvim_get_current_win() == winid then
        return
      end
      M.close(state)
    end,
  })
end

--- Bind buffer-local keymaps to close, expand, and collapse the float.
--- Keys are read from config; any key set to false is skipped entirely.
--- on_expand and on_collapse are closures provided by init.lua; nil = not registered.
---@param bufnr integer float buffer number
---@param state table
---@param on_expand function|nil callback for expand keymap
---@param on_collapse function|nil callback for collapse keymap
local function _setup_keymaps(bufnr, state, on_expand, on_collapse)
  --- Normalize a key config into a list of concrete mappings.
  --- Supports keypad aliases for default +/- so expand/collapse work with numpad.
  ---@param key string|string[]
  ---@return string[]
  local function key_list(key)
    if type(key) == "table" then return key end
    if key == "+" then return { "+", "<kPlus>" } end
    if key == "-" then return { "-", "<kMinus>" } end
    return { key }
  end

  local km    = require("ts_expand_hover.config").get().keymaps
  local close = function() M.close(state) end

  if km.close ~= false then
    for _, key in ipairs(key_list(km.close)) do
      vim.keymap.set("n", key, close, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  if on_expand and km.expand ~= false then
    for _, key in ipairs(key_list(km.expand)) do
      vim.keymap.set("n", key, function() on_expand() end, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  if on_collapse and km.collapse ~= false then
    for _, key in ipairs(key_list(km.collapse)) do
      vim.keymap.set("n", key, function() on_collapse() end, { buffer = bufnr, nowait = true, silent = true })
    end
  end
end

--- Open a focused float or update the existing one in-place.
--- Entry point called from init.lua on every LSP response.
---@param body table LSP response body { displayString, canIncreaseVerbosityLevel, ... }
---@param state table Session state
---@param on_expand function|nil callback fired when user presses + inside the float
---@param on_collapse function|nil callback fired when user presses - inside the float
function M.show(body, state, on_expand, on_collapse)
  local cfg    = require("ts_expand_hover.config").get().float
  local lines  = _build_lines(body)

  -- Store can_expand in state so expand/collapse handlers can read it without
  -- needing a reference to the full body table.
  state.can_expand = body and body.canIncreaseVerbosityLevel or false

  local width, height, footer = _compute_layout(lines, state, body, cfg)

  if state.float_winid and vim.api.nvim_win_is_valid(state.float_winid) then
    _update(lines, footer, width, height, state)
  else
    -- Capture source window before focus moves into the float.
    state.source_winid = vim.api.nvim_get_current_win()
    local win, buf = _open(lines, footer, width, height, state, cfg, on_expand, on_collapse)
    _setup_close_autocmds(win, state.source_bufnr, state)
    _setup_keymaps(buf, state, on_expand, on_collapse)
  end
end

--- Close the float window, clean up autocmds, and restore source focus.
--- Nils state handles before closing to prevent re-entrant calls.
---@param state table Session state
function M.close(state)
  local win    = state.float_winid
  local source = state.source_winid

  -- Nil state first — prevents re-entrant close if autocmd fires during close.
  state.float_winid  = nil
  state.float_bufnr  = nil
  state.source_winid = nil

  if win then
    pcall(vim.api.nvim_del_augroup_by_name, "ts_expand_hover_" .. win)
  end
  if win and vim.api.nvim_win_is_valid(win) then
    pcall(vim.api.nvim_win_close, win, true)
  end
  if source and vim.api.nvim_win_is_valid(source) then
    vim.api.nvim_set_current_win(source)
  end
end

return M
