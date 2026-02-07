local M = {}

---@param buf integer
---@param fn fun()
local function with_modifiable(buf, fn)
  local prev_modifiable = vim.bo[buf].modifiable
  local prev_readonly = vim.bo[buf].readonly

  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false

  local ok, err = pcall(fn)

  vim.bo[buf].modifiable = prev_modifiable
  vim.bo[buf].readonly = prev_readonly

  if not ok then
    error(err)
  end
end

M.with_buffer_mutation = with_modifiable

return M
