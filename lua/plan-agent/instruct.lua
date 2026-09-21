--- plan-agent.instruct: anchored instruction -> proposal -> accept/reject.
--- The anchor is an extmark, so it tracks edits above it. The agent never
--- writes the buffer; accept applies the proposal as one undo block.
local context = require("plan-agent.context")

local M = {}

local anchor_ns = vim.api.nvim_create_namespace("plan_agent_anchor")

---@type { bufnr: number, extmark: integer, instruction: string }|nil
local pending_anchor = nil
---@type { bufnr: number, anchor: integer, lines: string[], win: integer, buf: integer }|nil
local pending_proposal = nil

--- Open an instruction at the cursor line. Calls send(content) with the
--- propose prompt; the next assistant event becomes the proposal.
---@param send fun(content: string): boolean
function M.ask(send)
  if pending_anchor or pending_proposal then
    vim.notify("plan-agent: resolve the open instruction first", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local anchor = vim.api.nvim_win_get_cursor(0)[1]
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, anchor_ns, anchor - 1, 0, {
    right_gravity = false,
  })
  if not ok then
    vim.notify("plan-agent: cannot anchor instruction", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "@agent " }, function(instruction)
    if instruction == nil or instruction == "" then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, id)
      return
    end
    pending_anchor = { bufnr = bufnr, extmark = id, instruction = instruction }
    if not send(context.propose_prompt(bufnr, anchor, instruction)) then
      pending_anchor = nil
      pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, id)
      vim.notify("plan-agent: session is down", vim.log.levels.ERROR)
    end
  end)
end

--- Deliver assistant text: resolve the open instruction into a proposal.
--- Falls back to the cursor line when no instruction is open.
---@param text string
function M.deliver(text)
  local anchor = pending_anchor
  pending_anchor = nil
  local bufnr, line = nil, nil
  if anchor and vim.api.nvim_buf_is_valid(anchor.bufnr) then
    local pos = vim.api.nvim_buf_get_extmark_by_id(anchor.bufnr, anchor_ns, anchor.extmark, {})
    pcall(vim.api.nvim_buf_del_extmark, anchor.bufnr, anchor_ns, anchor.extmark)
    if pos and pos[1] then
      bufnr, line = anchor.bufnr, pos[1] + 1
    end
  end
  if not bufnr then
    bufnr = vim.api.nvim_get_current_buf()
    line = vim.api.nvim_win_get_cursor(0)[1]
  end
  local lines = vim.split(text, "\n", { plain = true })
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.cmd("botright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  pending_proposal = { bufnr = bufnr, anchor = line, lines = lines, win = win, buf = buf }
  vim.keymap.set("n", "<CR>", M.accept, { buffer = buf, nowait = true })
  vim.keymap.set("n", "q", M.reject, { buffer = buf, nowait = true })
  vim.notify("plan-agent: <CR> accept · q reject", vim.log.levels.INFO)
end

--- Apply the proposal after the anchor line. One undo block.
---@return boolean
function M.accept()
  local proposal = pending_proposal
  M.close_proposal()
  if not proposal or not vim.api.nvim_buf_is_valid(proposal.bufnr) then
    return false
  end
  local total = vim.api.nvim_buf_line_count(proposal.bufnr)
  local after = math.min(proposal.anchor, total)
  vim.api.nvim_buf_set_lines(proposal.bufnr, after, after, false, proposal.lines)
  return true
end

--- Discard the proposal. The buffer is untouched.
function M.reject()
  M.close_proposal()
  vim.notify("plan-agent: proposal rejected", vim.log.levels.INFO)
end

function M.close_proposal()
  if pending_proposal then
    pcall(vim.api.nvim_win_close, pending_proposal.win, true)
    pcall(vim.api.nvim_buf_delete, pending_proposal.buf, { force = true })
    pending_proposal = nil
  end
end

--- True while an instruction or proposal is open.
---@return boolean
function M.busy()
  return pending_anchor ~= nil or pending_proposal ~= nil
end

return M
