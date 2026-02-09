local utils = require("utils")

local ALLOWED_CHARACTERS = "A-Za-z0-9%-%(%).'’"

---@class State
---@field buf integer
---@field win integer
---@field timer? uv.uv_timer_t
---@field words string[]
---@field current_index integer
---@field running boolean
---@field wpm integer
local initial_state = {
  current_index = 1,
  running = false,
  wpm = 300,
}

---@type State
local state = vim.deepcopy(initial_state)

---@class Config
---@field auto_run boolean
---@field initial_wpm integer
---@field wpm_step_size integer
local config = {
  auto_run = true,
  wpm_step_size = 25,
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
  state.wpm = M.config.initial_wpm
end

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

local function write_status_line()
  local progress_str = string.format("%d/%d", state.current_index, #state.words)
  local wpm_str = string.format("WPM: %d", state.wpm)
  local progress_percentage = math.floor(state.current_index / #state.words * 100)
  local progress_percentage_str = string.format("%d%%", progress_percentage)
  local paused_text = not state.running and "[PAUSED]" or ""

  local status_line = string.format("%s %s | %s | %s", paused_text, progress_str, progress_percentage_str, wpm_str)

  local win_width = vim.api.nvim_win_get_width(0)
  local status_width = vim.fn.strdisplaywidth(status_line)
  local start_col = math.floor(win_width - status_width)

  local line = string.rep(" ", start_col) .. status_line

  utils.with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, { line })
  end)
end

M.play = function()
  if state.running then
    return
  end

  local interval = math.floor(60000 / state.wpm)
  state.running = true
  state.timer = vim.uv.new_timer()

  state.timer:start(
    interval,
    interval,
    vim.schedule_wrap(function()
      if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
        clear_timer()
        state.running = false
        return
      end

      if state.current_index > #state.words then
        clear_timer()
        state.running = false
        return
      end

      write_word(state.words[state.current_index])
      write_status_line()

      state.current_index = state.current_index + 1
      vim.cmd("redraw")
    end)
  )
end

M.pause = function()
  if not state.running then
    return
  end

  state.running = false
  clear_timer()
  write_status_line()
end

---@param diff integer
M.adjust_wpm = function(diff)
  local new_wpm = state.wpm + diff
  if new_wpm > 1000 then
    new_wpm = 1000
  elseif new_wpm < 50 then
    new_wpm = 50
  end

  state.wpm = new_wpm
  write_status_line()

  if state.timer then
    state.timer:set_repeat(math.floor(60000 / state.wpm))
  end
end

local function start_session()
  clear_timer()
  init_empty_buffer()
  write_status_line()

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
  vim.keymap.set(
    "n",
    "<",
    function()
      M.adjust_wpm(-M.config.wpm_step_size)
    end,
    { buffer = buf, nowait = true, silent = true, desc = string.format("Decrease WPM (-%d)", M.config.wpm_step_size) }
  )
  vim.keymap.set(
    "n",
    ">",
    function()
      M.adjust_wpm(M.config.wpm_step_size)
    end,
    { buffer = buf, nowait = true, silent = true, desc = string.format("Increase WPM (+%d)", M.config.wpm_step_size) }
  )

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
