--- plan-agent.ghost: completion block rendered below the cursor.
--- Virtual lines only: never interleaved with buffer text, never a
--- partial-word inline fragment. Zero buffer mutation until accept.
local log = require("plan-agent.log")

local M = {}

local ns = vim.api.nvim_create_namespace("plan_agent_ghost")

---@class PlanAgentGhost
---@field bufnr number
---@field row number 0-indexed insertion line
---@field col number insertion column
---@field text string

---@type PlanAgentGhost|nil
local current = nil

--- Show completion text as virtual lines under row. Replaces any ghost.
--- pos defaults to the current cursor; pass the request cursor so a
--- moved cursor cannot misplace the block.
---@param bufnr number
---@param text string non-empty completion text
---@param pos { row: integer, col: integer }|nil 0-indexed insertion point
---@return boolean shown
function M.show(bufnr, text, pos)
  if text == nil or text == "" then
    return false
  end
  M.clear()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local row, col
  if pos then
    row, col = pos.row, pos.col
  else
    local cursor = vim.api.nvim_win_get_cursor(0)
    row, col = cursor[1] - 1, cursor[2]
  end
  local total = vim.api.nvim_buf_line_count(bufnr)
  if row < 0 or row >= total then
    return false
  end
  local virt = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    virt[#virt + 1] = { { line, "Comment" } }
  end
  virt[#virt + 1] = { { "Tab accept · move on dismiss", "Comment" } }
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
    virt_lines = virt,
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

--- Insert the pending ghost at its recorded position. Single undo block.
--- Scheduled: expr mappings run under textlock.
---@return boolean accepted
function M.accept()
  local ghost = current
  M.clear()
  if not ghost or not vim.api.nvim_buf_is_valid(ghost.bufnr) then
    return false
  end
  local total = vim.api.nvim_buf_line_count(ghost.bufnr)
  local row = math.max(0, math.min(ghost.row, total - 1))
  local bufnr = ghost.bufnr
  local lines = vim.split(ghost.text, "\n", { plain = true })
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local col = math.min(ghost.col, #line)
    vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)
  end)
  return true
end

return M
