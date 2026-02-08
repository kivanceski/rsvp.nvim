local M = {}

---@param buf integer
---@param fn fun()
local function with_modifiable(buf, fn)
  vim.bo[buf].modifiable = true
  vim.bo[buf].readonly = false

  local ok, err = pcall(fn)

  vim.bo[buf].modifiable = false
  vim.bo[buf].readonly = true

  if not ok then
    error(err)
  end
end

M.with_buffer_mutation = with_modifiable

return M
