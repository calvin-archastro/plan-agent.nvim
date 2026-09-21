--- plan-agent.log: in-memory ring log plus :PlanAgentLog viewer.
--- info+ always recorded; debug only when enabled via setup({debug=true}).
local M = {}

local max_entries = 200
local debug_enabled = false
local entries = {}

--- Enable or silence debug entries.
---@param on boolean
function M.enable_debug(on)
  debug_enabled = on == true
end

---@param level string
---@param msg string
function M.log(level, msg)
  entries[#entries + 1] = { t = os.date("%H:%M:%S"), level = level, msg = msg }
  while #entries > max_entries do
    table.remove(entries, 1)
  end
end

function M.debug(msg)
  if debug_enabled then
    M.log("debug", msg)
  end
end

function M.info(msg)
  M.log("info", msg)
end

function M.warn(msg)
  M.log("warn", msg)
end

function M.error(msg)
  M.log("error", msg)
end

--- Formatted lines, oldest first.
---@return string[]
function M.lines()
  local out = {}
  for _, e in ipairs(entries) do
    out[#out + 1] = string.format("[%s] %-5s %s", e.t, e.level, e.msg)
  end
  return out
end

--- Number of retained entries (tests).
---@return integer
function M.count()
  return #entries
end

--- Open the log in a scratch split.
function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, M.lines())
  vim.api.nvim_buf_set_option(buf, "filetype", "plan-agent-log")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), buf)
end

return M
