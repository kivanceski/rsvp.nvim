---@class RsvpModule
local M = {}

local TIMER_SENSITIVITY = 100

local hl_ns = vim.api.nvim_create_namespace("rsvp_hl")

local HL_GROUPS = {
  main = "RsvpMain",
  accent = "RsvpAccent",
  paused = "RsvpPaused",
  done = "RsvpDone",
  ghost_text = "RsvpGhostText",
}

local default_highlights = {
  main = { link = "Keyword" },
  accent = { link = "ErrorMsg" },
  paused = { fg = "#FFFF00", bold = true },
  done = { fg = "#00FF00", bold = true },
  ghost_text = { link = "NonText" },
}

local LINE_INDICES = {
  status_line = 0,
  elapsed_time_line = 3,
  keymap_line = -1,
  help_line = -2,
  progress_bar = -5,
}

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
---@field elapsed_timer? uv.uv_timer_t
---@field elapsed_ticks integer
---@field words string[]
---@field current_index integer
---@field running boolean
---@field finished boolean
---@field wpm integer
local initial_state = {
  current_index = 1,
  running = false,
  finished = false,
  wpm = 300,
  elapsed_ticks = 0,
}

---@type State
local state = vim.deepcopy(initial_state)

---@alias RsvpHighlightOpts vim.api.keyset.highlight

---@class RsvpColors
---@field main? RsvpHighlightOpts
---@field accent? RsvpHighlightOpts
---@field paused? RsvpHighlightOpts
---@field done? RsvpHighlightOpts
---@field ghost_text? RsvpHighlightOpts

---@class Config
---@field keymaps Keymaps
---@field auto_run boolean
---@field initial_wpm integer
---@field wpm_step_size integer
---@field progress_bar_width integer
---@field surrounding_word_count integer
---@field colors RsvpColors
local config = {
  keymaps = keymaps,
  auto_run = true,
  initial_wpm = 300,
  wpm_step_size = 25,
  progress_bar_width = 80,
  surrounding_word_count = 1,
  colors = {},
}

---@type Config
M.config = config

---@param linenr integer
---@param buf integer?
local function get_abs_linenr(linenr, buf)
  return vim.api.nvim_buf_line_count(buf or state.buf) + linenr
end

---@param buf integer
---@param line integer
---@param str string
---@param pattern string
---@param hl_group string
---@param opts? { start_col?: integer, plain?: boolean }
local function set_hl_group(buf, line, str, pattern, hl_group, opts)
  opts = opts or {}
  local start_col = opts.start_col or 1
  local plain = opts.plain ~= false
  local s, e = str:find(pattern, start_col, plain)
  if s == nil then
    return
  end
  vim.api.nvim_buf_set_extmark(buf, hl_ns, line, s - 1, { end_col = e, hl_group = hl_group })
end

local function init_highlights()
  for color_name, hl_group in pairs(HL_GROUPS) do
    local hl_spec = vim.deepcopy(default_highlights[color_name])
    local color_override = M.config.colors[color_name] or {}

    if next(color_override) ~= nil then
      local has_link = color_override.link ~= nil
      if not has_link then
        hl_spec.link = nil
      end
      hl_spec = vim.tbl_deep_extend("force", hl_spec, color_override)
    end

    vim.api.nvim_set_hl(0, hl_group, hl_spec)
  end
end

---@param value any
---@return integer
local function sanitize_surrounding_word_count(value)
  local count = tonumber(value)
  if count == nil then
    return 1
  end

  if count % 1 ~= 0 then
    return 1
  end

  if count < 0 or count > 3 then
    return 1
  end

  return math.floor(count)
end

---@param args Config?
-- you can define your setup function here. Usually configurations can be merged, accepting outside params and
-- you can also put some validation here for those.
M.setup = function(args)
  M.config = vim.tbl_deep_extend("force", M.config, args or {})
  M.config.surrounding_word_count = sanitize_surrounding_word_count(M.config.surrounding_word_count)
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

local function clear_elapsed_timer()
  if state.elapsed_timer then
    state.elapsed_timer:stop()
    state.elapsed_timer:close()
    state.elapsed_timer = nil
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
    "Play/Pause: <Space>",
    "Reset: r",
    string.format("Decrease WPM (-%d):  %s", M.config.wpm_step_size, M.config.keymaps.decrease_wpm),
    string.format("Increase WPM (+%d):  %s", M.config.wpm_step_size, M.config.keymaps.increase_wpm),
    string.format("Previous step:  %s", M.config.keymaps.previous_step),
    string.format("Next step:  %s", M.config.keymaps.next_step),
    "",
    "Help: g?",
  }
end

---@param buf integer
---@param help_text string[]
local function highlight_help_keymaps(buf, help_text)
  local help_keymaps = {
    { line = 1, keys = { "q", "<Esc>" } },
    { line = 3, keys = { "<Space>" } },
    { line = 4, keys = { "r" } },
    { line = 5, keys = { M.config.keymaps.decrease_wpm } },
    { line = 6, keys = { M.config.keymaps.increase_wpm } },
    { line = 7, keys = { M.config.keymaps.previous_step } },
    { line = 8, keys = { M.config.keymaps.next_step } },
    { line = 10, keys = { "g?" } },
  }

  for _, help_line in ipairs(help_keymaps) do
    local line = help_text[help_line.line]
    if line then
      local _, colon_end = line:find(":%s*")
      local start_col = colon_end and (colon_end + 1) or 1
      for _, key in ipairs(help_line.keys) do
        set_hl_group(buf, help_line.line - 1, line, key, HL_GROUPS.main, { start_col = start_col })
      end
    end
  end
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
---@return integer
local function get_orp_char_index(word)
  local char_count = vim.fn.strchars(word)
  if char_count == 0 then
    return 1
  end

  local alnum_positions = {}
  for i = 1, char_count do
    local char = vim.fn.strcharpart(word, i - 1, 1)
    if char:match("[%w]") then
      table.insert(alnum_positions, i)
    end
  end

  local alnum_count = #alnum_positions
  if alnum_count == 0 then
    return 1
  end

  local core_orp_index
  if alnum_count <= 1 then
    core_orp_index = 1
  elseif alnum_count <= 5 then
    core_orp_index = 2
  elseif alnum_count <= 9 then
    core_orp_index = 3
  elseif alnum_count <= 13 then
    core_orp_index = 4
  else
    core_orp_index = 5
  end

  core_orp_index = math.max(1, math.min(core_orp_index, alnum_count))

  return alnum_positions[core_orp_index]
end

---@param word_index integer
---@return string line
---@return integer orp_col_start
---@return integer orp_col_end
---@return { start_col: integer, end_col: integer }[] ghost_ranges
local function build_orp_line(word_index)
  local word = state.words[word_index]
  local win_width = vim.api.nvim_win_get_width(state.win or 0)
  local surrounding_word_count = sanitize_surrounding_word_count(M.config.surrounding_word_count)

  local words_start_index = math.max(1, word_index - surrounding_word_count)
  local words_end_index = math.min(#state.words, word_index + surrounding_word_count)

  local displayed_word_segments = {}
  local surrounding_word_char_ranges = {}
  local current_word_start_char_index = 0
  local char_cursor = 0

  for i = words_start_index, words_end_index do
    local token = state.words[i]

    if #displayed_word_segments > 0 then
      table.insert(displayed_word_segments, " ")
      char_cursor = char_cursor + 1
    end

    local token_start_char_index = char_cursor
    local token_char_count = vim.fn.strchars(token)
    table.insert(displayed_word_segments, token)
    char_cursor = char_cursor + token_char_count

    if i == word_index then
      current_word_start_char_index = token_start_char_index
    else
      table.insert(surrounding_word_char_ranges, {
        start_char_index = token_start_char_index,
        end_char_index = token_start_char_index + token_char_count,
      })
    end
  end

  local displayed_words = table.concat(displayed_word_segments, "")
  local orp_char_index = get_orp_char_index(word)
  local displayed_orp_char_index = current_word_start_char_index + (orp_char_index - 1)
  local prefix = vim.fn.strcharpart(displayed_words, 0, displayed_orp_char_index)
  local prefix_width = vim.fn.strdisplaywidth(prefix)
  local center_col = math.floor((win_width - 1) / 2)
  local start_col = math.max(0, center_col - prefix_width)

  local line = string.rep(" ", start_col) .. displayed_words

  local orp_byte_start = start_col + vim.str_byteindex(displayed_words, "utf-32", displayed_orp_char_index)
  local orp_char = vim.fn.strcharpart(word, orp_char_index - 1, 1)
  local orp_byte_end = orp_byte_start + math.max(1, #orp_char)

  local ghost_ranges = {}
  for _, char_range in ipairs(surrounding_word_char_ranges) do
    table.insert(ghost_ranges, {
      start_col = start_col + vim.str_byteindex(displayed_words, "utf-32", char_range.start_char_index),
      end_col = start_col + vim.str_byteindex(displayed_words, "utf-32", char_range.end_char_index),
    })
  end

  return line, orp_byte_start, orp_byte_end, ghost_ranges
end

---@param word_index integer
local function write_word(word_index)
  local line_number = math.floor(vim.o.lines / 2)
  local line, orp_col_start, orp_col_end, surrounding_ranges = build_orp_line(word_index)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, line_number, line_number + 1, false, { line })
  end)

  vim.api.nvim_buf_clear_namespace(state.buf, hl_ns, line_number, line_number + 1)
  vim.api.nvim_buf_set_extmark(state.buf, hl_ns, line_number, orp_col_start, {
    end_col = orp_col_end,
    hl_group = HL_GROUPS.accent,
  })

  for _, range in ipairs(surrounding_ranges) do
    if range.end_col > range.start_col then
      vim.api.nvim_buf_set_extmark(state.buf, hl_ns, line_number, range.start_col, {
        end_col = range.end_col,
        hl_group = HL_GROUPS.ghost_text,
      })
    end
  end
end

---@param word_index? integer
local function write_status_line(word_index)
  local word_count = #state.words
  local current_word_index = math.max(1, math.min(word_count, word_index or state.current_index))

  local progress_str = string.format("%d/%d", current_word_index, word_count)
  local wpm_str = string.format("WPM: %d", state.wpm)
  local progress_percentage = math.floor(current_word_index / word_count * 100)
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
  set_hl_group(state.buf, LINE_INDICES.status_line, line, "PAUSED", HL_GROUPS.paused)
end

local function write_elapsed_time_line()
  local elapsed_line = string.format("DONE in %.2f second(s)!", state.elapsed_ticks / TIMER_SENSITIVITY)

  local line = center_text(elapsed_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(
      state.buf,
      LINE_INDICES.elapsed_time_line,
      LINE_INDICES.elapsed_time_line + 1,
      false,
      { line }
    )
  end)
  set_hl_group(state.buf, LINE_INDICES.elapsed_time_line, line, "DONE", HL_GROUPS.done)
end

local function clear_elapsed_time_line()
  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(
      state.buf,
      LINE_INDICES.elapsed_time_line,
      LINE_INDICES.elapsed_time_line + 1,
      false,
      { "" }
    )
  end)
end

---@return integer
local function get_current_word_index()
  return math.max(1, math.min(#state.words, state.current_index - 1))
end

---@param word_index? integer
local write_proggress_bar = function(word_index)
  local word_count = #state.words
  local current_word_index = math.max(0, math.min(word_count, word_index or state.current_index))
  local progress_ratio = current_word_index / word_count

  local progress_count = math.floor(M.config.progress_bar_width * progress_ratio)

  local progress_str = string.rep("█", progress_count)
  local unfinished_str = string.rep("▒", M.config.progress_bar_width - progress_count)

  local line = center_text(progress_str .. unfinished_str)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.progress_bar - 1, LINE_INDICES.progress_bar, false, { line })
  end)

  set_hl_group(state.buf, get_abs_linenr(LINE_INDICES.progress_bar), line, progress_str, HL_GROUPS.main)
  set_hl_group(state.buf, get_abs_linenr(LINE_INDICES.progress_bar), line, unfinished_str, HL_GROUPS.ghost_text)
end

local function write_help_line()
  local help_line = "Help: g?"

  local line = center_text(help_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.help_line - 1, LINE_INDICES.help_line, false, { line })
  end)
  set_hl_group(state.buf, get_abs_linenr(LINE_INDICES.help_line), line, "g?", HL_GROUPS.main)
end

local function write_keymap_line()
  local decrease_wpm = "Decrease WPM (-" .. M.config.wpm_step_size .. "): " .. M.config.keymaps.decrease_wpm

  local increase_wpm = "Increase WPM (+" .. M.config.wpm_step_size .. "): " .. M.config.keymaps.increase_wpm

  local keymap_line = string.format("%s | PLAY/PAUSE: <Space> | %s", decrease_wpm, increase_wpm)

  local line = center_text(keymap_line)

  with_buffer_mutation(state.buf, function()
    vim.api.nvim_buf_set_lines(state.buf, LINE_INDICES.keymap_line - 1, LINE_INDICES.keymap_line, false, { line })
  end)

  set_hl_group(
    state.buf,
    get_abs_linenr(LINE_INDICES.keymap_line),
    line,
    string.format(" %s ", M.config.keymaps.decrease_wpm),
    HL_GROUPS.main
  )
  set_hl_group(state.buf, get_abs_linenr(LINE_INDICES.keymap_line), line, "<Space>", HL_GROUPS.main)
  set_hl_group(
    state.buf,
    get_abs_linenr(LINE_INDICES.keymap_line),
    line,
    string.format(" %s$", M.config.keymaps.increase_wpm),
    HL_GROUPS.main,
    { plain = false }
  )
end

M.play = function()
  if state.running or state.finished then
    return
  end

  local interval = math.floor(60000 / state.wpm)
  state.running = true
  state.timer = vim.uv.new_timer()

  if not state.elapsed_timer then
    state.elapsed_timer = vim.uv.new_timer()
  end

  state.elapsed_timer:start(
    1000 / TIMER_SENSITIVITY,
    1000 / TIMER_SENSITIVITY,
    vim.schedule_wrap(function()
      state.elapsed_ticks = state.elapsed_ticks + 1
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
        clear_elapsed_timer()
        write_elapsed_time_line()

        state.finished = true
        state.running = false
        return
      end

      write_word(state.current_index)
      write_status_line(state.current_index)
      write_proggress_bar(state.current_index)

      state.current_index = state.current_index + 1
      vim.cmd("redraw")
    end)
  )
end

M.pause = function()
  if not state.running then
    return
  end

  state.elapsed_timer:stop()
  state.running = false
  clear_timer()
  write_status_line(get_current_word_index())
end

---@param relative_step integer
M.set_step = function(relative_step)
  local current_word_index = get_current_word_index()
  local target_word_index = current_word_index + relative_step

  if target_word_index > #state.words or target_word_index < 1 then
    return
  end

  M.pause()
  state.current_index = target_word_index + 1
  state.finished = false
  clear_elapsed_time_line()
  write_word(target_word_index)
  write_status_line(target_word_index)
  write_proggress_bar(target_word_index)
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
  highlight_help_keymaps(bufnr, help_text)

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
  vim.api.nvim_buf_clear_namespace(state.buf, hl_ns, 0, -1)
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
    write_word(state.current_index)
    write_status_line(state.current_index)
    write_proggress_bar(state.current_index)
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
  init_highlights()

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  local win_state = create_floating_window()
  state = vim.tbl_deep_extend("force", state, win_state)

  vim.keymap.set("n", "<Space>", M.toggle, { buffer = state.buf, nowait = true, silent = true })
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
  for token in full_content_str:gmatch("%S+") do
    local core = token:gsub("^[^%w]+", ""):gsub("[^%w]+$", "")
    if core:match("%a") then
      table.insert(words, token)
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
