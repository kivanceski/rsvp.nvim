local ALLOWED_CHARACTERS = "A-Za-z0-9%-%(%).'’"

---@class Keymaps
---@field decrease_wpm string
---@field increase_wpm string
local keymaps = {
  reset = "r",
  decrease_wpm = "<",
  increase_wpm = ">",
  previous_step = "H",
  next_step = "L",
}

---@class State
---@field buf integer
---@field win integer
---@field timer? uv.uv_timer_t
---@field duration_timer? uv.uv_timer_t
---@field duration integer
---@field words string[]
---@field current_index integer
---@field running boolean
---@field finished boolean
---@field wpm integer
local initial_state = {
  current_index = 1,
  running = false,
  wpm = 300,
  duration = 0,
}

---@type State
local state = vim.deepcopy(initial_state)

---@class Config
---@field keymaps Keymaps
---@field auto_run boolean
---@field initial_wpm integer
---@field wpm_step_size integer
local config = {
  keymaps = keymaps,
  auto_run = true,
  wpm_step_size = 25,
}

---@class RsvpModule
local M = {}

---@type Config
M.config = config

local TIMER_SENSITIVITY = 100

local hl_ns = vim.api.nvim_create_namespace("rsvp_hl")

local HL_GROUPS = {
  main = "RsvpMain",
  accent = "RsvpAccent",
  ghost_text = "RsvpGhostText",
}

local LINE_INDICES = {
  status_line = 0,
  duration_line = 3,
  keymap_line = -1,
  help_line = -2,
  progress_bar = -7,
}

---@param buf integer
---@param line integer
---@param str string
---@param pattern string
---@param hl_group string
local function set_hl_group(buf, line, str, pattern, hl_group)
  local s, e = str:find(pattern)
  local linenr = vim.api.nvim_buf_line_count(buf) + line
  vim.api.nvim_buf_set_extmark(buf, hl_ns, linenr, s - 1, { end_col = e, hl_group = hl_group })
end

local function init_highlights()
  vim.api.nvim_set_hl(0, "RsvpMain", { link = "@keyword" })
  vim.api.nvim_set_hl(0, "RsvpAccent", { link = "@keyword" })
  vim.api.nvim_set_hl(0, "RsvpGhostText", { link = "NonText" })
end

---@param args Config?
-- you can define your setup function here. Usually configurations can be merged, accepting outside params and
-- you can also put some validation here for those.
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
  state.wpm = M.config.initial_wpm
  init_highlights()
end

local function clear_timer()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function clear_duration_timer()
  if state.duration_timer then
    state.duration_timer:stop()
    state.duration_timer:close()
    state.duration_timer = nil
  end
end

---@param buf integer
---@param fn fun()
local function with_buffer_mutation(buf, fn)
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false

  local ok, err = pcall(fn)

  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  if not ok then
    error(err)
  end
end

local function init_empty_buffer()
  local empty_lines = {}

  for _ = 1, vim.o.lines - 2 do
    table.insert(empty_lines, "")
  end

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, empty_lines)
  end)
end

---@return string[]
local function get_help_text()
  return {
    "RSVP Help (Quit: q or <Esc>)",
    "",
    "Play/Pause: <space>",
    'Reset: "r"',
    string.format("Decrease WPM (-%d):  %s", M.config.wpm_step_size, '"<"'),
    string.format("Increase WPM (+%d):  %s", M.config.wpm_step_size, '">"'),
    string.format('Previous step:  "%s"', M.config.keymaps.previous_step),
    string.format('Next step:  "%s"', M.config.keymaps.next_step),
    "",
    'Help: "g?"',
  }
end

local function close_rsvp()
  pcall(vim.api.nvim_win_close, state.win, true)
  state = vim.tbl_deep_extend("force", state, initial_state)
end

---@param text string
---@return string
local function center_text(text)
  local win_width = vim.api.nvim_win_get_width(0)
  local text_width = vim.fn.strdisplaywidth(text)
  local start_col = math.max(0, math.floor((win_width - text_width) / 2))

  local line = string.rep(" ", start_col) .. text

  return line
end

---@param word string
local function write_word(word)
  local line_number = math.floor(vim.o.lines / 2)
  local line = center_text(word)

  with_buffer_mutation(state.buf, function()
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
  local start_col = math.floor(win_width - status_width - 8)

  local line = string.rep(" ", start_col) .. status_line

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.status_line, LINE_INDICES.status_line + 1, false, { line })
  end)
end

local function write_duration_line()
  local duration_line = string.format("DONE in %.2f second(s)!", state.duration / TIMER_SENSITIVITY)

  local line = center_text(duration_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.duration_line, LINE_INDICES.duration_line + 1, false, { line })
  end)
end

local write_proggress_bar = function()
  local progress_bar_width = 80

  local progress_ratio = state.current_index / #state.words

  local progress_count = math.floor(progress_bar_width * progress_ratio)

  local progress_str = string.rep("█", progress_count)
  local unfinished_str = string.rep("▒", progress_bar_width - progress_count)

  local line = center_text(progress_str .. unfinished_str)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.progress_bar, LINE_INDICES.progress_bar + 1, false, { line })
  end)
end

local function write_help_line()
  local help_line = 'Help: "g?"'

  local line = center_text(help_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.help_line, LINE_INDICES.help_line, false, { line })
  end)
end

local function write_keymap_line()
  local decrease_wpm = "Decrease WPM (-"
    .. M.config.wpm_step_size
    .. "): "
    .. '"'
    .. M.config.keymaps.decrease_wpm
    .. '"'

  local increase_wpm = "Increase WPM (+"
    .. M.config.wpm_step_size
    .. "): "
    .. '"'
    .. M.config.keymaps.increase_wpm
    .. '"'

  local keymap_line = string.format("%s | PLAY/PAUSE: <space> | %s", decrease_wpm, increase_wpm)

  local line = center_text(keymap_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.keymap_line, LINE_INDICES.keymap_line, false, { line })
  end)
end

M.play = function()
  if state.running then
    return
  end

  local interval = math.floor(60000 / state.wpm)
  state.running = true
  state.timer = vim.uv.new_timer()

  if not state.duration_timer then
    state.duration_timer = vim.uv.new_timer()
  end

  state.duration_timer:start(
    1000 / TIMER_SENSITIVITY,
    1000 / TIMER_SENSITIVITY,
    vim.schedule_wrap(function()
      state.duration = state.duration + 1
    end)
  )

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
        clear_duration_timer()
        write_duration_line()

        state.finished = true
        state.running = false
        return
      end

      write_word(state.words[state.current_index])
      write_status_line()
      write_proggress_bar()

      state.current_index = state.current_index + 1
      vim.cmd("redraw")
    end)
  )
end

M.pause = function()
  if not state.running then
    return
  end

  state.duration_timer:stop()
  state.running = false
  clear_timer()
  write_status_line()
end

---@param relative_step integer
M.set_step = function(relative_step)
  if state.current_index + relative_step > #state.words or state.current_index + relative_step < 1 then
    return
  end
  M.pause()
  state.current_index = state.current_index + relative_step
  write_word(state.words[state.current_index])
  write_status_line()
end

M.toggle = function()
  if state.running then
    M.pause()
  else
    M.play()
  end
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

local function render_help()
  M.pause()
  local bufnr = vim.api.nvim_create_buf(false, true)

  local help_text = get_help_text()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, help_text)

  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].readonly = true

  local width = 80
  local height = #help_text + 2

  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    style = "minimal",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
  })

  local function close_help()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  vim.keymap.set("n", "q", close_help, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", close_help, { buffer = bufnr, nowait = true, silent = true })
end

local function render()
  write_status_line()
  write_keymap_line()
  write_help_line()
end

local function start_session()
  clear_timer()
  init_empty_buffer()
  render()

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

local function init_rsvp_window()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local win_state = create_floating_window()
  state = vim.tbl_deep_extend("force", state, win_state)

  vim.keymap.set("n", "<space>", M.toggle, { buffer = state.buf, nowait = true, silent = true })
  vim.keymap.set("n", "r", M.reset, { buffer = state.buf, nowait = true, silent = true })
  vim.keymap.set("n", M.config.keymaps.decrease_wpm, function()
    M.adjust_wpm(-M.config.wpm_step_size)
  end, {
    buffer = state.buf,
    nowait = true,
    silent = true,
    desc = string.format("Decrease WPM (-%d)", M.config.wpm_step_size),
  })
  vim.keymap.set("n", M.config.keymaps.increase_wpm, function()
    M.adjust_wpm(M.config.wpm_step_size)
  end, {
    buffer = state.buf,
    nowait = true,
    silent = true,
    desc = string.format("Increase WPM (+%d)", M.config.wpm_step_size),
  })

  vim.keymap.set("n", M.config.keymaps.previous_step, function()
    M.set_step(-1)
  end, { buffer = state.buf, nowait = true, silent = true, desc = "Previous step" })

  vim.keymap.set("n", M.config.keymaps.next_step, function()
    M.set_step(1)
  end, { buffer = state.buf, nowait = true, silent = true, desc = "Next step" })

  vim.keymap.set(
    "n",
    "g?",
    render_help,
    { buffer = state.buf, nowait = true, silent = true, desc = "RSVP - Open help" }
  )

  vim.api.nvim_create_autocmd("VimResized", {
    callback = function()
      init_empty_buffer()
      render()
    end,
  })

  -- attach cleanup
  vim.api.nvim_create_autocmd({ "BufWipeout", "BufUnload" }, {
    buffer = state.buf,
    once = true,
    callback = close_rsvp,
  })
end

M.reset = function()
  close_rsvp()
  init_rsvp_window()
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

  if #words == 0 then
    vim.notify("No words found", vim.log.levels.ERROR)
    return
  end
  state.words = words

  init_rsvp_window()
  start_session()
end

return M
