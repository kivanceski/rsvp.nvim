local M = {}

---@param win_id integer?
M.close_win = function(win_id)
  win_id = win_id or 0
  vim.api.nvim_win_close(win_id, true)
end

--- @type vim.api.keyset.win_config
local floating_window_config = {
  width = vim.o.columns,
  height = vim.o.lines,
  relative = "editor",
  col = 0,
  row = 0,
  style = "minimal",
}

M.create_floating_window = function()
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, floating_window_config)

  -- vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"

  vim.keymap.set("n", "q", M.close_win, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set("n", "<Esc>", M.close_win, { buffer = buf, nowait = true, silent = true })

  return { buf = buf, win = win }
end

return M
