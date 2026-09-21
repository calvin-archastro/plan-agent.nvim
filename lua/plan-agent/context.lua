--- plan-agent.context: full buffer plus a marked focus region.
--- Ghost focus: anchor ±10 lines. Propose focus: anchor ±30 lines.
--- The whole doc goes in (plans are small); the focus region says WHERE,
--- and the changed note says what moved since the last request.
local M = {}

--- Soft cap: larger buffers keep head, focus, and tail with an omission note.
M.max_lines = 500

--- Read the lines around a 1-indexed anchor line, clamped to the buffer.
---@param bufnr number
---@param anchor integer 1-indexed
---@param radius integer lines each side
---@return string[] lines, integer first 1-indexed line number
function M.window(bufnr, anchor, radius)
  local total = vim.api.nvim_buf_line_count(bufnr)
  anchor = math.max(1, math.min(anchor, total))
  local first = math.max(1, anchor - radius)
  local last = math.min(total, anchor + radius)
  return vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false), first
end

--- Render a window as numbered text for the prompt.
---@param lines string[]
---@param first integer 1-indexed number of lines[1]
---@return string
function M.render(lines, first)
  local out = {}
  for i, line in ipairs(lines) do
    out[#out + 1] = string.format("%d: %s", first + i - 1, line)
  end
  return table.concat(out, "\n")
end

--- Unified-diff section for local edits, or nil when there is nothing new.
--- The model reads hunks directly; + lines are the current buffer.
---@param diff string|nil
---@return string|nil
function M.diff_section(diff)
  if diff == nil or diff == "" then
    return nil
  end
  return "Local edits since last request (unified diff, + lines are current):\n" .. diff
end

--- Full numbered doc with the focus region marked and middle truncated
--- past the cap.
---@param bufnr number
---@param anchor integer 1-indexed
---@param radius integer focus half-width
---@return string
function M.document(bufnr, anchor, radius)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines
  anchor = math.max(1, math.min(anchor, math.max(total, 1)))
  local out = {}
  local omitted = 0
  local focus_first = math.max(1, anchor - radius)
  local focus_last = math.min(total, anchor + radius)
  for i, line in ipairs(lines) do
    local in_focus = math.abs(i - anchor) <= radius
    local keep = in_focus or i <= 25 or i > total - 25
    if total <= M.max_lines or keep then
      if i == focus_first then
        out[#out + 1] = ">>> FOCUS (cursor at line " .. anchor .. ")"
      end
      out[#out + 1] = string.format("%d: %s", i, line)
      if i == focus_last then
        out[#out + 1] = "<<< END FOCUS"
      end
    else
      omitted = omitted + 1
    end
  end
  if omitted > 0 then
    out[#out + 1] = "[... " .. omitted .. " lines omitted outside focus ...]"
  end
  return table.concat(out, "\n")
end

--- Ghost prompt: full doc, marked focus, reply text only.
---@param bufnr number
---@param anchor integer 1-indexed
---@param diff string|nil unified diff of local edits
---@return string
function M.suggest_prompt(bufnr, anchor, diff)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local parts = {
    "File: " .. path,
    "Cursor line: " .. anchor,
    "Full document (focus marked):",
    M.document(bufnr, anchor, 10),
  }
  local section = M.diff_section(diff)
  if section then
    parts[#parts + 1] = section
  end
  -- Directive last: models follow trailing instructions most reliably.
  -- It restates the whole job so a long document cannot bury it.
  parts[#parts + 1] = "Task: write ONLY the new continuation text for the cursor line above. "
    .. "No fences, no explanation, no narration, no questions. "
    .. "Never repeat text already in the document. "
    .. "If there is nothing to add, reply with an empty string."
  return table.concat(parts, "\n")
end

--- Propose prompt: full doc, marked focus, answer with added lines only.
---@param bufnr number
---@param anchor integer 1-indexed
---@param instruction string
---@param diff string|nil unified diff of local edits
---@return string
function M.propose_prompt(bufnr, anchor, instruction, diff)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local parts = {
    "File: " .. path,
    "Instruction at line " .. anchor .. ": " .. instruction,
    "Full document (focus marked):",
    M.document(bufnr, anchor, 30),
  }
  local section = M.diff_section(diff)
  if section then
    parts[#parts + 1] = section
  end
  parts[#parts + 1] = "Task: reply with ONLY the Markdown lines for the instruction above. "
    .. "No fences, no explanation, no narration. "
    .. "Reply with an empty string to delete the target range."
  return table.concat(parts, "\n")
end

--- Whole-document pass prompt: the full doc plus one instruction.
---@param bufnr number
---@param instruction string
---@param diff string|nil unified diff of local edits
---@return string
function M.pass_prompt(bufnr, instruction, diff)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local parts = {
    "File: " .. path,
    "Instruction for a full-document pass: " .. instruction,
    "Complete current document:",
    table.concat(lines, "\n"),
  }
  local section = M.diff_section(diff)
  if section then
    parts[#parts + 1] = section
  end
  parts[#parts + 1] = "Task: apply the instruction to the whole document above. "
    .. "Reply with ONLY the complete revised document, no fences, no explanation, no narration. "
    .. "Keep every part outside the instruction's scope byte-identical."
  return table.concat(parts, "\n")
end

return M
