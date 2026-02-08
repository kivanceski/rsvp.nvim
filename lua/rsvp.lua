local utils = require("utils")

---@class Config
---@field auto_run boolean
---@field initial_wpm integer
local config = {
  auto_run = true,
  initial_wpm = 300,
}

---@class RsvpModule
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
---@field timer? uv.uv_timer_t
---@field words string[]
---@field current_index integer
---@field running boolean
local initial_state = {
  current_index = 1,
  running = false,
}

---@type State
local state = vim.deepcopy(initial_state)

local function clear_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
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

local function close_rsvp()
  pcall(vim.api.nvim_win_close, state.win, true)
  state = vim.tbl_deep_extend("force", state, initial_state)
end

---@param word string
local function write_word(word)
  local line_number = math.floor(vim.o.lines / 2)
  local win_width = vim.api.nvim_win_get_width(0)
  local word_width = vim.fn.strdisplaywidth(word)
  local start_col = math.max(0, math.floor((win_width - word_width) / 2))

  local line = string.rep(" ", start_col) .. word

  utils.with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, line_number, line_number + 1, false, { line })
  end)
end

M.play = function()
  if state.running then
    return
  end

  local interval = math.floor(60000 / M.config.initial_wpm)
  state.running = true
  state.timer = vim.uv.new_timer()

  state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        clear_timer()
        return
      end

      if state.current_index > #state.words then
        clear_timer()
        return
      end

      write_word(state.words[state.current_index])

      state.current_index = state.current_index + 1
    end)
  )
end

M.pause = function()
  if not state.running then
    return
  end

  state.running = false
  clear_timer()
end

local function start_session()
  clear_timer()
  init_empty_buffer()

  if M.config.auto_run then
    M.play()
  else
    write_word(state.words[state.current_index])
    state.current_index = state.current_index + 1
  end
end

-- WINDOW LOGIC

---@type vim.api.keyset.win_config
local floating_window_config = {
  width = vim.o.columns,
  height = vim.o.lines,
  relative = "editor",
  col = 0,
  row = 0,
  style = "minimal",
}

local function create_floating_window()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, floating_window_config)

  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].readonly = true

  -- attach keymaps
  vim.keymap.set("n", "q", close_rsvp, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close_rsvp, { buffer = buf, nowait = true, silent = true })

  return { buf = buf, win = win }
end

local function init_window()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local win_state = create_floating_window()
  state = vim.tbl_deep_extend("force", state, win_state)

  -- attach cleanup
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = state.buf,
    once = true,
    callback = close_rsvp,
  })
end

M.refresh = function()
  close_rsvp()
  init_window()
  start_session()
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

  state.words = words

  init_window()
  start_session()
end

return M
