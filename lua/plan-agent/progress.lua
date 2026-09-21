--- plan-agent.progress: elapsed-time marker while a request is in flight.
---
--- A single end-of-line virtual note on the buffer's first line:
---   ◌ pass… 4s
--- Virtual only: no buffer text, no undo entries, survives typing. One
--- marker at a time; starting a new request replaces the old one.
local M = {}

local progress_ns = vim.api.nvim_create_namespace("plan_agent_progress")
local mark_id = nil ---@type integer|nil
local mark_buf = nil ---@type number|nil
local mark_label = "working" ---@type string
local timer = nil
local started_at = 0

--- Stop the timer. Keeps the mark; callers clear it via stop().
local function halt_timer()
  if timer then
    timer:stop()
    timer = nil
  end
end

--- Paint the current elapsed time. Exposed for tests.
function M.refresh()
  if not mark_id or not mark_buf or not vim.api.nvim_buf_is_valid(mark_buf) then
    return
  end
  local secs = math.max(0, math.floor(os.time() - started_at))
  local label = mark_label or "working"
  pcall(
    vim.api.nvim_buf_set_extmark,
    mark_buf,
    progress_ns,
    0,
    0,
    {
      id = mark_id,
      virt_text = { { "◌ " .. label .. "… " .. secs .. "s", "Comment" } },
      virt_text_pos = "eol",
    }
  )
end

--- Show the marker for one in-flight request.
---@param bufnr number
---@param label string e.g. "pass", "instruct", "suggest"
function M.start(bufnr, label)
  M.stop()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  mark_label = label
  mark_buf = bufnr
  started_at = os.time()
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, progress_ns, 0, 0, {
    virt_text = { { "◌ " .. label .. "… 0s", "Comment" } },
    virt_text_pos = "eol",
  })
  if not ok then
    mark_buf = nil
    return
  end
  mark_id = id
  local function tick()
    timer = nil
    if not mark_id then
      return
    end
    M.refresh()
    timer = vim.defer_fn(tick, 1000)
  end
  timer = vim.defer_fn(tick, 1000)
end

--- Clear the marker and timer. Safe to call with none active.
function M.stop()
  halt_timer()
  if mark_id and mark_buf and vim.api.nvim_buf_is_valid(mark_buf) then
    pcall(vim.api.nvim_buf_del_extmark, mark_buf, progress_ns, mark_id)
  end
  mark_id = nil
  mark_buf = nil
end

--- True while the marker is up. Exposed for tests.
---@return boolean
function M.visible()
  return mark_id ~= nil
end

return M
