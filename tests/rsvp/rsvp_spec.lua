local function close_floating_windows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function setup_rsvp(opts)
  local merged_opts = vim.tbl_deep_extend("force", { auto_run = false }, opts or {})
  require("rsvp").setup(merged_opts)
end

local function open_rsvp_session(lines, opts)
  local rsvp = require("rsvp")
  setup_rsvp(opts)

  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(input_buf)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, lines)
  rsvp.rsvp({ line1 = 1, line2 = #lines })
end

local function find_line_with(buf, token)
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(token, 1, true) then
      return i - 1, line
    end
  end

  error(string.format("could not find token '%s' in RSVP window", token))
end

local function line_contains(buf, token)
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(token, 1, true) then
      return true
    end
  end

  return false
end

local function get_progress_counts(buf)
  local _, line = find_line_with(buf, "▒")
  local bar = vim.trim(line)
  local _, completed = bar:gsub("█", "")
  local _, unfinished = bar:gsub("▒", "")
  return completed, unfinished
end

local function get_line_extmark_texts(buf, line_idx, hl_group)
  local ns = vim.api.nvim_get_namespaces().rsvp_hl
  assert(ns ~= nil, "rsvp_hl namespace should exist")

  local line = vim.api.nvim_buf_get_lines(buf, line_idx, line_idx + 1, false)[1]
  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, { line_idx, 0 }, { line_idx, -1 }, { details = true })
  local texts = {}

  for _, mark in ipairs(extmarks) do
    local col = mark[3]
    local details = mark[4]
    if details and details.hl_group == hl_group then
      table.insert(texts, line:sub(col + 1, details.end_col))
    end
  end

  return texts
end

local function get_accent_char(token)
  open_rsvp_session({ token })

  local buf = vim.api.nvim_get_current_buf()
  local line_idx = find_line_with(buf, token)

  for _, text in ipairs(get_line_extmark_texts(buf, line_idx, "RsvpAccent")) do
    if #text > 0 then
      return text:sub(1, 1)
    end
  end

  error("RsvpAccent extmark not found")
end

describe("rsvp ORP highlighting", function()
  before_each(function()
    package.loaded.rsvp = nil
    setup_rsvp()
  end)

  after_each(function()
    close_floating_windows()
  end)

  it("does not highlight underscore in snake_case identifiers", function()
    assert.are.equal("G", get_accent_char("HL_GROUPS"))
  end)

  it("ignores surrounding punctuation when picking ORP", function()
    assert.are.equal("e", get_accent_char("(hello)"))
  end)

  it("matches Spritz-style ORP buckets by alphanumeric length", function()
    local cases = {
      { token = "a", accent = "a" },
      { token = "to", accent = "o" },
      { token = "words", accent = "o" },
      { token = "reading", accent = "a" },
      { token = "attention", accent = "t" },
      { token = "developing", accent = "e" },
      { token = "characterization", accent = "a" },
    }

    for _, case in ipairs(cases) do
      assert.are.equal(case.accent, get_accent_char(case.token), case.token)
    end
  end)

  it("shows configured surrounding words and highlights them as ghost text", function()
    local rsvp = require("rsvp")
    open_rsvp_session({ "alpha beta gamma delta epsilon" }, { surrounding_word_count = 1 })

    -- initial word is index 1; step once to display index 2 (beta) with both sides
    rsvp.set_step(1)

    local buf = vim.api.nvim_get_current_buf()
    local line_idx, line = find_line_with(buf, "beta")
    assert.is_truthy(line:find("alpha beta gamma", 1, true))
    assert.same({ "alpha", "gamma" }, get_line_extmark_texts(buf, line_idx, "RsvpGhostText"))
  end)

  it("does not add extra words near boundaries", function()
    open_rsvp_session({ "one two three" }, { surrounding_word_count = 1 })

    local buf = vim.api.nvim_get_current_buf()
    local _, line = find_line_with(buf, "one")
    assert.are.equal("one two", vim.trim(line))
  end)

  it("treats invalid surrounding_word_count as one", function()
    open_rsvp_session({ "one two three" }, { surrounding_word_count = 5 })

    local buf = vim.api.nvim_get_current_buf()
    local line_idx, line = find_line_with(buf, "one")
    assert.are.equal("one two", vim.trim(line))
    assert.same({ "two" }, get_line_extmark_texts(buf, line_idx, "RsvpGhostText"))
  end)

  it("treats non-integer surrounding_word_count as one", function()
    open_rsvp_session({ "one two three" }, { surrounding_word_count = 1.5 })

    local buf = vim.api.nvim_get_current_buf()
    local line_idx, line = find_line_with(buf, "one")
    assert.are.equal("one two", vim.trim(line))
    assert.same({ "two" }, get_line_extmark_texts(buf, line_idx, "RsvpGhostText"))
  end)
end)

describe("rsvp step navigation", function()
  before_each(function()
    package.loaded.rsvp = nil
    setup_rsvp()
  end)

  after_each(function()
    close_floating_windows()
  end)

  it("moves one word and updates status/progress on next step", function()
    local rsvp = require("rsvp")
    open_rsvp_session({ "alpha beta gamma delta" })

    rsvp.set_step(1)

    local buf = vim.api.nvim_get_current_buf()
    local _, status_line = find_line_with(buf, "2/4")
    assert.is_truthy(status_line:find("50%", 1, true))
    find_line_with(buf, "beta")

    local completed, unfinished = get_progress_counts(buf)
    assert.are.equal(40, completed)
    assert.are.equal(40, unfinished)
  end)

  it("clears DONE line and rewinds progress when stepping back after finish", function()
    local rsvp = require("rsvp")
    open_rsvp_session({ "one two" })
    rsvp.play()

    local reached_done = vim.wait(2000, function()
      local buf = vim.api.nvim_get_current_buf()
      return line_contains(buf, "DONE in")
    end, 20)

    assert.is_true(reached_done)

    local buf = vim.api.nvim_get_current_buf()
    assert.is_true(line_contains(buf, "DONE in"))
    local done_line_idx = find_line_with(buf, "DONE in")
    assert.same({ "DONE" }, get_line_extmark_texts(buf, done_line_idx, "RsvpDone"))

    rsvp.set_step(-1)

    assert.is_false(line_contains(buf, "DONE in"))
    local _, status_line = find_line_with(buf, "1/2")
    assert.is_truthy(status_line:find("50%", 1, true))

    local completed, unfinished = get_progress_counts(buf)
    assert.are.equal(40, completed)
    assert.are.equal(40, unfinished)
  end)
end)
