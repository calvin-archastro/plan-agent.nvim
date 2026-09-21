--- plan-agent.instruct: sigil-anchored instructions over a line range.
---
--- Normal ga: zero-width range at the cursor (pure insert after the line).
--- Visual ga: the selected lines (replace, possibly with nothing = delete).
---
--- Asking inserts a real sigil line after the range:
---   <!-- ◌ plan-agent:<id> <instruction> -->
--- The session works in the background while you keep writing. On
--- completion the range is replaced with the proposal (one undo block).
--- Delete the sigil line and the result is dropped.
local context = require("plan-agent.context")
local log = require("plan-agent.log")

local M = {}

local anchor_ns = vim.api.nvim_create_namespace("plan_agent_anchor")

---@type { bufnr: number, sigil: integer, start_mark: integer, end_mark: integer, id: string }|nil
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

--- Track a line with an extmark. Returns the mark id or nil.
---@param bufnr number
---@param row0 integer 0-indexed
---@param gravity boolean right gravity
---@return integer|nil
local function track(bufnr, row0, gravity)
  local ok, id = pcall(
    vim.api.nvim_buf_set_extmark,
    bufnr,
    anchor_ns,
    row0,
    0,
    { right_gravity = gravity }
  )
  if not ok then
    return nil
  end
  return id
end

local function untrack(bufnr, id)
  pcall(vim.api.nvim_buf_del_extmark, bufnr, anchor_ns, id)
end

---@class PlanAgentRange
---@field srow integer 0-indexed inclusive start
---@field erow integer 0-indexed exclusive end

--- Open an instruction. Calls send(content) with the propose prompt; the
--- assistant reply replaces the range. opts.range defaults to a zero-width
--- range at the cursor (insert after the line). opts.diff_fn(bufnr) supplies
--- the local-edits diff, computed after the note is submitted.
---@param send fun(content: string): boolean
---@param opts { range: PlanAgentRange|nil, diff_fn: fun(bufnr: number): string|nil }|nil
function M.ask(send, opts)
  if pending_anchor then
    vim.notify("plan-agent: an instruction is already running", vim.log.levels.WARN)
    return
  end
  local range = (opts and opts.range) or nil
  local bufnr = vim.api.nvim_get_current_buf()
  if not range then
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    range = { srow = cursor, erow = cursor }
  end
  vim.ui.input({ prompt = "@agent " }, function(instruction)
    if instruction == nil or instruction == "" then
      return
    end
    local id = new_id()
    vim.api.nvim_buf_set_lines(bufnr, range.erow, range.erow, false, { M.sigil(id, instruction) })
    local sigil = track(bufnr, range.erow, true)
    local start_mark = track(bufnr, range.srow, false)
    local end_mark = track(bufnr, range.erow, false)
    if not sigil or not start_mark or not end_mark then
      if sigil then
        untrack(bufnr, sigil)
      end
      if start_mark then
        untrack(bufnr, start_mark)
      end
      if end_mark then
        untrack(bufnr, end_mark)
      end
      vim.notify("plan-agent: cannot anchor instruction", vim.log.levels.ERROR)
      return
    end
    pending_anchor = { bufnr = bufnr, sigil = sigil, start_mark = start_mark, end_mark = end_mark, id = id }
    local anchor_line = range.srow + 1
    log.info("instruction asked lines " .. (range.srow + 1) .. "-" .. range.erow .. " id=" .. id)
    local diff = opts and opts.diff_fn and opts.diff_fn(bufnr) or nil
    if not send(context.propose_prompt(bufnr, anchor_line, instruction, diff)) then
      pending_anchor = nil
      untrack(bufnr, sigil)
      untrack(bufnr, start_mark)
      untrack(bufnr, end_mark)
      vim.notify("plan-agent: session is down", vim.log.levels.ERROR)
    else
      M.working(0)
    end
  end)
end

--- Resolve a tracked mark to a 0-indexed row, or nil.
---@param bufnr number
---@param id integer
---@return integer|nil
local function resolve(bufnr, id)
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, anchor_ns, id, {})
  if not pos or not pos[1] then
    return nil
  end
  return pos[1]
end

--- Working marker (virtual, undo-free) on the sigil line while streaming.
---@param chars integer streamed so far
function M.working(chars)
  local anchor = pending_anchor
  if not anchor or not vim.api.nvim_buf_is_valid(anchor.bufnr) then
    return
  end
  local text = chars > 0 and ("◌ agent working… " .. chars .. " chars") or "◌ agent working…"
  local row = resolve(anchor.bufnr, anchor.sigil)
  if not row then
    return
  end
  pcall(vim.api.nvim_buf_set_extmark, anchor.bufnr, anchor_ns, row, 0, {
    id = anchor.sigil,
    virt_text = { { text, "Comment" } },
    virt_text_pos = "eol",
  })
end

--- True when the reply reads as conversational chatter ("I'm ready but I
--- don't see…", "Send the…") rather than the requested Markdown. Plan prose
--- almost never opens this way; when it fires the buffer stays untouched.
--- Exposed for tests.
---@param text string
---@return boolean
function M.chatty(text)
  local trimmed = text:gsub("^%s+", "")
  for _, opening in ipairs({ "I'm ", "I don't ", "I can't " }) do
    if trimmed:sub(1, #opening) == opening then
      return true
    end
  end
  if trimmed:find("Send the ", 1, true) and trimmed:find("plus what", 1, true) then
    return true
  end
  return false
end

--- Deliver assistant text: replace the range with the proposal.
--- An empty proposal deletes the range. A deleted sigil vetoes the job:
--- the result is dropped, buffer untouched. Chatty non-answers are dropped
--- the same way, with a warning instead of writing chatter into the doc.
---@param text string
function M.deliver(text)
  local anchor = pending_anchor
  pending_anchor = nil
  if not anchor or not vim.api.nvim_buf_is_valid(anchor.bufnr) then
    return
  end
  if M.chatty(text) then
    local sigil_row =
      vim.api.nvim_buf_get_extmark_by_id(anchor.bufnr, anchor_ns, anchor.sigil, {})[1]
    untrack(anchor.bufnr, anchor.sigil)
    untrack(anchor.bufnr, anchor.start_mark)
    untrack(anchor.bufnr, anchor.end_mark)
    if sigil_row then
      pcall(vim.api.nvim_buf_set_lines, anchor.bufnr, sigil_row, sigil_row + 1, false, {})
    end
    log.info("instruction dropped: chatty reply id=" .. anchor.id)
    vim.notify(
      "plan-agent: agent asked for clarification, dropped (:PlanAgentLog)",
      vim.log.levels.WARN
    )
    return
  end
  local sigil_row = resolve(anchor.bufnr, anchor.sigil)
  local srow = resolve(anchor.bufnr, anchor.start_mark)
  local erow = resolve(anchor.bufnr, anchor.end_mark)
  untrack(anchor.bufnr, anchor.sigil)
  untrack(anchor.bufnr, anchor.start_mark)
  untrack(anchor.bufnr, anchor.end_mark)
  if sigil_row == nil or srow == nil or erow == nil then
    log.info("instruction dropped: anchor lost id=" .. anchor.id)
    return
  end
  local sigil_line = vim.api.nvim_buf_get_lines(anchor.bufnr, sigil_row, sigil_row + 1, false)[1]
  if not sigil_line or not sigil_line:find(anchor.id, 1, true) then
    log.info("instruction dropped: sigil deleted id=" .. anchor.id)
    return
  end
  -- Remove the sigil first so positions below stay stable, then replace.
  vim.api.nvim_buf_set_lines(anchor.bufnr, sigil_row, sigil_row + 1, false, {})
  local total = vim.api.nvim_buf_line_count(anchor.bufnr)
  srow = math.max(0, math.min(srow, total))
  erow = math.max(srow, math.min(erow, total))
  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 1 and lines[1] == "" then
    lines = {}
  end
  vim.api.nvim_buf_set_lines(anchor.bufnr, srow, erow, false, lines)
  log.info("proposal applied: " .. #lines .. " lines id=" .. anchor.id)
  vim.notify("plan-agent: proposal applied (u to undo)", vim.log.levels.INFO)
end

--- True while an instruction is in flight.
---@return boolean
function M.busy()
  return pending_anchor ~= nil
end

return M
