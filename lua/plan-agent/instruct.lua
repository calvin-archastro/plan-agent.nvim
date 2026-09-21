--- plan-agent.instruct: sigil-anchored instructions.
---
--- Asking inserts a real sigil line after the cursor:
---   <!-- ◌ plan-agent:<id> <instruction> -->
--- The session works in the background while you keep writing. On
--- completion the sigil line is replaced with the proposal (one undo
--- block). Delete the sigil line and the result is dropped.
local context = require("plan-agent.context")
local log = require("plan-agent.log")

local M = {}

local anchor_ns = vim.api.nvim_create_namespace("plan_agent_anchor")

---@type { bufnr: number, extmark: integer, id: string }|nil
local pending_anchor = nil

--- Short unique id for one instruction.
---@return string
local function new_id()
  return vim.fn.sha256(tostring(os.time()) .. tostring(math.random())):sub(1, 8)
end

--- The sigil line text. Plain HTML comment: visible in source, inert.
---@param id string
---@param instruction string
---@return string
function M.sigil(id, instruction)
  local short = instruction:gsub("%s+", " "):sub(1, 60)
  return "<!-- ◌ plan-agent:" .. id .. " " .. short .. " -->"
end

--- Open an instruction at the cursor line. Calls send(content) with the
--- propose prompt; the assistant reply replaces the sigil line.
---@param send fun(content: string): boolean
function M.ask(send)
  if pending_anchor then
    vim.notify("plan-agent: an instruction is already running", vim.log.levels.WARN)
    return
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local anchor = vim.api.nvim_win_get_cursor(0)[1]
  vim.ui.input({ prompt = "@agent " }, function(instruction)
    if instruction == nil or instruction == "" then
      return
    end
    local id = new_id()
    vim.api.nvim_buf_set_lines(bufnr, anchor, anchor, false, { M.sigil(id, instruction) })
    local ok, extmark = pcall(
      vim.api.nvim_buf_set_extmark,
      bufnr,
      anchor_ns,
      anchor,
      0,
      { right_gravity = true }
    )
    if not ok then
      vim.notify("plan-agent: cannot anchor instruction", vim.log.levels.ERROR)
      return
    end
    pending_anchor = { bufnr = bufnr, extmark = extmark, id = id }
    log.info("instruction asked at line " .. anchor .. " id=" .. id)
    if not send(context.propose_prompt(bufnr, anchor, instruction)) then
      pending_anchor = nil
      pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, extmark)
      pcall(vim.api.nvim_buf_set_lines, bufnr, anchor, anchor + 1, false, {})
      vim.notify("plan-agent: session is down", vim.log.levels.ERROR)
    else
      M.working(0)
    end
  end)
end

--- Working marker (virtual, undo-free) on the sigil line while streaming.
---@param chars integer streamed so far
function M.working(chars)
  local anchor = pending_anchor
  if not anchor or not vim.api.nvim_buf_is_valid(anchor.bufnr) then
    return
  end
  local text = chars > 0 and ("◌ agent working… " .. chars .. " chars") or "◌ agent working…"
  local pos = vim.api.nvim_buf_get_extmark_by_id(anchor.bufnr, anchor_ns, anchor.extmark, {})
  if not pos or not pos[1] then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, anchor.bufnr, anchor_ns, pos[1], pos[2], {
    id = anchor.extmark,
    virt_text = { { text, "Comment" } },
    virt_text_pos = "eol",
  })
end

--- Deliver assistant text: replace the sigil line with the proposal.
--- A deleted sigil vetoes the job: the result is dropped, buffer untouched.
---@param text string
function M.deliver(text)
  local anchor = pending_anchor
  pending_anchor = nil
  if not anchor or not vim.api.nvim_buf_is_valid(anchor.bufnr) then
    return
  end
  local pos = vim.api.nvim_buf_get_extmark_by_id(anchor.bufnr, anchor_ns, anchor.extmark, {})
  pcall(vim.api.nvim_buf_del_extmark, anchor.bufnr, anchor_ns, anchor.extmark)
  if not pos or not pos[1] then
    log.info("instruction dropped: anchor lost id=" .. anchor.id)
    return
  end
  local lnum = pos[1] + 1
  local line = vim.api.nvim_buf_get_lines(anchor.bufnr, lnum - 1, lnum, false)[1]
  if not line or not line:find(anchor.id, 1, true) then
    log.info("instruction dropped: sigil deleted id=" .. anchor.id)
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(anchor.bufnr, lnum - 1, lnum, false, lines)
  log.info("proposal applied: " .. #lines .. " lines id=" .. anchor.id)
  vim.notify("plan-agent: proposal applied (u to undo)", vim.log.levels.INFO)
end

--- True while an instruction is in flight.
---@return boolean
function M.busy()
  return pending_anchor ~= nil
end

return M
