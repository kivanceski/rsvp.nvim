local window = require("window")
local utils = require("utils")

---@class Config
---@field auto_run boolean
---@field initial_wpm integer
local config = {
  auto_run = true,
  initial_wpm = 300,
}

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

local ALLOWED_CHARACTERS = "A-Za-z0-9%-%(%).'’"

---@class State
---@field buf integer
---@field win integer
---@field timer integer
---@field words string[]
---@field current_index integer
local initial_state = {
  current_index = 1,
}

---@type State
local state = vim.deepcopy(initial_state)

local function stop_timer()
  if state.timer then
    vim.fn.timer_stop(state.timer)
    state.timer = nil
  end
end

local function init_empty_buffer()
  local empty_lines = {}

  for _ = 1, vim.o.lines do
    table.insert(empty_lines, "")
  end

  utils.with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, empty_lines)
  end)
end

M.play = function()
  local line_number = math.floor(vim.o.lines / 2)
  local win_width = vim.api.nvim_win_get_width(0)

  local time = math.floor(60000 / config.initial_wpm)
  state.timer = vim.fn.timer_start(time, function(timer)
    if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
      vim.fn.timer_stop(timer)
      return
    end

    if state.current_index > #state.words then
      vim.fn.timer_stop(timer)
      state.timer = nil
      return
    end

    local word = state.words[state.current_index]
    local word_width = vim.fn.strdisplaywidth(word)
    local start_col = math.max(0, math.floor((win_width - word_width) / 2))

    local line = string.rep(" ", start_col) .. word

    utils.with_buffer_mutation(state.buf, function()
      vim.api.nvim_buf_set_lines(state.buf, line_number, line_number + 1, false, { line })
    end)

    state.current_index = state.current_index + 1
  end, { ["repeat"] = -1 })
end

M.pause = function()
  stop_timer()
end

local function start_session()
  stop_timer()
  init_empty_buffer()

  if config.auto_run then
    M.play()
  end
end

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

  local win_state = window.create_floating_window()
  state = vim.tbl_deep_extend("force", vim.deepcopy(initial_state), win_state)
  state.words = words

  -- attach cleanup
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = state.buf,
    once = true,
    callback = function()
      stop_timer()
      state.buf = nil
      state.win = nil
    end,
  })

  start_session()
end

return M
