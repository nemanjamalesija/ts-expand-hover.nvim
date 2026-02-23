--- Float lifecycle module for ts-expand-hover.nvim.
--- Handles open, in-place update, auto-close autocmds, and buffer-local keymaps.

local M = {}

--- Split body.displayString into content lines.
---@param body table LSP response body with displayString field
---@return string[]
local function _build_lines(body)
  if not body or not body.displayString then
    return { "(no type info)" }
  end
  return vim.split(body.displayString, "\n", { plain = true })
end

--- Build the footer hint string showing current verbosity and available keys.
---@param state table Session state with verbosity field
---@return string
local function _build_footer(state)
  return string.format(
    "depth: %d  [+] expand  [-] collapse  [q] close",
    state.verbosity or 0
  )
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

--- Open a new focused floating window with the given content.
---@param lines string[]
---@param footer_text string
---@param state table
---@param cfg table float config (border, max_width, max_height)
---@return integer win, integer buf
local function _open(lines, footer_text, state, cfg)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile  = false
  vim.bo[buf].modifiable = true

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width  = math.min(cfg.max_width,  _max_line_width(lines))
  local height = math.min(cfg.max_height, #lines)

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
---@param state table
---@param cfg table
local function _update(lines, footer_text, state, cfg)
  local buf = state.float_bufnr
  local win = state.float_winid

  if not vim.api.nvim_win_is_valid(win) then return end
  if not vim.api.nvim_buf_is_valid(buf) then return end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local width  = math.min(cfg.max_width,  _max_line_width(lines))
  local height = math.min(cfg.max_height, #lines)

  -- Read existing config first so relative, footer_pos, etc. are preserved.
  local existing = vim.api.nvim_win_get_config(win)
  existing.width  = width
  existing.height = height
  existing.footer = { { footer_text, "FloatFooter" } }
  vim.api.nvim_win_set_config(win, existing)
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

--- Bind buffer-local q and Esc keys to close the float.
---@param bufnr integer float buffer number
---@param state table
local function _setup_keymaps(bufnr, state)
  local close = function() M.close(state) end
  vim.keymap.set("n", "q",     close, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, nowait = true, silent = true })
end

--- Open a focused float or update the existing one in-place.
--- Entry point called from init.lua on every LSP response.
---@param body table LSP response body { displayString, canIncreaseVerbosityLevel, ... }
---@param state table Session state
function M.show(body, state)
  local cfg    = require("ts_expand_hover.config").get().float
  local lines  = _build_lines(body)
  local footer = _build_footer(state)

  if state.float_winid and vim.api.nvim_win_is_valid(state.float_winid) then
    _update(lines, footer, state, cfg)
  else
    -- Capture source window before focus moves into the float.
    state.source_winid = vim.api.nvim_get_current_win()
    local win, buf = _open(lines, footer, state, cfg)
    _setup_close_autocmds(win, state.source_bufnr, state)
    _setup_keymaps(buf, state)
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
