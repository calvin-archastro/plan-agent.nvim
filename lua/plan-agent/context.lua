--- plan-agent.context: build the anchor windows sent to the session.
--- Ghost: anchor ±10 lines. Propose: anchor ±30 lines. Never the repo.
local M = {}

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

--- Ghost prompt: continue the text at the anchor line, reply text only.
---@param bufnr number
---@param anchor integer 1-indexed
---@return string
function M.suggest_prompt(bufnr, anchor)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines, first = M.window(bufnr, anchor, 10)
  return table.concat({
    "File: " .. path,
    "Cursor line: " .. anchor,
    "Reply with ONLY the completion text for the cursor position, no fences, no explanation.",
    "Context:",
    M.render(lines, first),
  }, "\n")
end

--- Propose prompt: answer the instruction with added lines only.
---@param bufnr number
---@param anchor integer 1-indexed
---@param instruction string
---@return string
function M.propose_prompt(bufnr, anchor, instruction)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local lines, first = M.window(bufnr, anchor, 30)
  return table.concat({
    "File: " .. path,
    "Instruction at line " .. anchor .. ": " .. instruction,
    "Reply with ONLY the Markdown lines to insert after line "
      .. anchor
      .. ", no fences, no explanation.",
    "Context:",
    M.render(lines, first),
  }, "\n")
end

return M
