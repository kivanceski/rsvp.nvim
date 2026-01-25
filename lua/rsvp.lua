local window = require("window")

---@class Config
local config = {}

---@class MyModule
local M = {}

---@type Config
M.config = config

---@param args Config?
-- you can define your setup function here. Usually configurations can be merged, accepting outside params and
-- you can also put some validation here for those.
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
end

local ALLOWED_CHARACTERS = "A-Za-z%-%(%).'’"

---@type {buf: integer?, win: integer?, timer: integer?}
local state = {}

local function center_text(content)
  -- center horizontally
  local pad = math.max(0, math.floor((vim.o.columns - #content) / 2))
  local line_centered = string.rep(" ", pad) .. content

  -- center vertically
  local win_height = vim.api.nvim_win_get_height(0)
  local top_pad = math.floor((win_height - 1) / 2)
  local padded = {}
  for _ = 1, top_pad do
    table.insert(padded, "")
  end
  table.insert(padded, line_centered)

  return padded
end

local function stop_timer()
  if state.timer then
    pcall(vim.fn.timer_stop, state.timer)
    state.timer = nil
  end
end

local function attach_cleanup()
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = state.buf,
    once = true,
    callback = function()
      stop_timer()
      state.buf = nil
      state.win = nil
    end,
  })
end

--- Executes rsvp display for given list of words
---@param words string[] list of words to display
local execute_words = function(words)
  stop_timer()

  local i = 1
  state.timer = vim.fn.timer_start(200, function(timer)
    if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
      vim.fn.timer_stop(timer)
      return
    end

    if i > #words then
      vim.fn.timer_stop(timer)
      state.timer = nil
      return
    end

    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, center_text(words[i]))
    i = i + 1
  end, { ["repeat"] = -1 })
end

-- cleanup on buffer close
vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
  buffer = state.buf,
  once = true,
  callback = function()
    if state.timer then
      vim.fn.timer_stop(state.timer)
    end
  end,
})

---@param opts vim.api.keyset.create_user_command.command_args
M.rsvp = function(opts)
  local start = opts.line1
  local end_ = opts.line2

  local full_content = vim.api.nvim_buf_get_lines(0, start - 1, end_, false)
  local full_content_str = table.concat(full_content, " ")

  local words = {}
  for word in full_content_str:gmatch("%w+") do
    if word:match("%a") and word:match("^[" .. ALLOWED_CHARACTERS .. "]+$") then
      table.insert(words, word)
    end
  end

  state = window.create_floating_window()
  attach_cleanup()
  execute_words(words)
end

return M
