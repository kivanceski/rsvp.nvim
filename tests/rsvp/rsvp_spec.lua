local function close_floating_windows()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    local config = vim.api.nvim_win_get_config(win)
    if config.relative ~= "" then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function get_accent_char(token)
  local rsvp = require("rsvp")

  local input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(input_buf)
  vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { token })
  rsvp.rsvp({ line1 = 1, line2 = 1 })

  local buf = vim.api.nvim_get_current_buf()
  local ns = vim.api.nvim_get_namespaces().rsvp_hl
  assert(ns ~= nil, "rsvp_hl namespace should exist")

  local line_idx
  local line_content
  for i, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
    if line:find(token, 1, true) then
      line_idx = i - 1
      line_content = line
      break
    end
  end

  assert(line_idx ~= nil, "could not find token in RSVP window")

  local extmarks = vim.api.nvim_buf_get_extmarks(buf, ns, { line_idx, 0 }, { line_idx, -1 }, { details = true })
  for _, mark in ipairs(extmarks) do
    local col = mark[3]
    local details = mark[4]
    if details and details.hl_group == "RsvpAccent" then
      return line_content:sub(col + 1, col + 1)
    end
  end

  error("RsvpAccent extmark not found")
end

describe("rsvp ORP highlighting", function()
  before_each(function()
    package.loaded.rsvp = nil
    require("rsvp").setup({ auto_run = false })
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
end)
