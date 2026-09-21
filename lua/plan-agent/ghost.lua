--- plan-agent.ghost: extmark ghost overlay for the next completion.
--- Zero buffer mutation until accept. One pending ghost at a time.
local log = require("plan-agent.log")

local M = {}

local ns = vim.api.nvim_create_namespace("plan_agent_ghost")

---@class PlanAgentGhost
---@field bufnr number
---@field row number 0-indexed cursor line when shown
---@field col number cursor column when shown
---@field text string

---@type PlanAgentGhost|nil
local current = nil

--- Show ghost text at the cursor position. Replaces any pending ghost.
---@param bufnr number
---@param text string non-empty completion text
---@return boolean shown
function M.show(bufnr, text)
  if text == nil or text == "" then
    return false
  end
  M.clear()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row, col = cursor[1] - 1, cursor[2]
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
    virt_text = { { text, "Comment" } },
    virt_text_pos = "inline",
    hl_mode = "combine",
  })
  if not ok then
    return false
  end
  current = { bufnr = bufnr, row = row, col = col, text = text, id = id }
  log.debug("ghost shown: len=" .. #text)
  return true
end

--- Dismiss the pending ghost, if any.
function M.clear()
  if current and vim.api.nvim_buf_is_valid(current.bufnr) then
    pcall(vim.api.nvim_buf_del_extmark, current.bufnr, ns, current.id)
  end
  current = nil
end

--- The pending ghost, or nil.
---@return PlanAgentGhost|nil
function M.current()
  return current
end

--- Insert the pending ghost at the cursor. Single undo block.
--- The edit is scheduled: expr mappings run under textlock, which forbids
--- buffer writes inline. Cursor and buffer are captured synchronously.
---@return boolean accepted
function M.accept()
  local ghost = current
  M.clear()
  if not ghost or not vim.api.nvim_buf_is_valid(ghost.bufnr) then
    return false
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1
  local col = cursor[2]
  local lines = vim.split(ghost.text, "\n", { plain = true })
  local bufnr = ghost.bufnr
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)
    local last = lines[#lines]
    if #lines > 1 then
      vim.api.nvim_win_set_cursor(0, { row + #lines, #last })
    else
      vim.api.nvim_win_set_cursor(0, { row + 1, col + #last })
    end
  end)
  return true
end

return M
