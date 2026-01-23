-- main module file
-- local module = require("plugin_name.module")

---@class Config
---@field opt string Your config option
local config = {
  opt = "Hello!",
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

local width = 80
local height = 20

--- @type vim.api.keyset.win_config
local floating_window_config = {
  width = width,
  height = height,
  border = "rounded",
  relative = "editor",
  row = math.floor((vim.o.lines - height) / 2),
  col = math.floor((vim.o.columns - width) / 2),
  style = "minimal",
}

local function create_floating_window()
  --
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_open_win(bufnr, true, floating_window_config)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, { "Hello World!" })
end
create_floating_window()

return M
