--- plan-agent: background archdev sidecar for co-editing docs/plans.
--- Ghost completions via Tab, anchored instructions via g a.
--- The agent proposes; only your keypress writes the buffer.
local session = require("plan-agent.session")
local ghost = require("plan-agent.ghost")
local context = require("plan-agent.context")
local instruct = require("plan-agent.instruct")

local M = {}

local defaults = {
  binary = "archdev",
  model = nil,
  permission_mode = "deny",
  debounce_ms = 350,
  -- Enabled when the buffer path contains any entry (plain substring).
  paths = { "docs/plans/" },
  prompt = "You co-edit a Markdown plan beside the user. "
    .. "Reply with ONLY the requested text: no fences, no explanation.",
}

local config = vim.deepcopy(defaults)
---@type table|nil session handle from session.start
local handle = nil
local pending_kind = nil ---@type "suggest"|"propose"|nil
local pending_buf = nil ---@type number|nil
local pending_seq = 0
local timer = nil

--- Buffer-local opt-out wins, then opt-in, then path matching.
---@param bufnr number|nil
---@return boolean
local function is_enabled(bufnr)
  bufnr = bufnr or 0
  local override = vim.b[bufnr].plan_agent_enabled
  if override ~= nil then
    return override
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  for _, entry in ipairs(config.paths) do
    if name:find(entry, 1, true) ~= nil then
      return true
    end
  end
  return false
end

--- Statusline fragment: PA:idle | PA:working | PA:proposal | PA:down.
---@return string
function M.status()
  if instruct.busy() or ghost.current() then
    return "PA:proposal"
  end
  if pending_kind then
    return "PA:working"
  end
  if handle and handle.running() then
    return "PA:idle"
  end
  return "PA:down"
end

--- Start the persistent session. Idempotent.
---@return boolean
function M.start()
  if handle and handle.running() then
    return true
  end
  M.stop()
  local cmd = { config.binary, "agents", "run", config.prompt, "--stream" }
  if config.model then
    vim.list_extend(cmd, { "--model", config.model })
  end
  if config.permission_mode then
    vim.list_extend(cmd, { "--permission-mode", config.permission_mode })
  end
  local new_handle, err = session.start({
    cmd = cmd,
    on_event = function(event)
      vim.schedule(function()
        M.on_event(event)
      end)
    end,
    on_malformed = function(line)
      vim.schedule(function()
        vim.notify("plan-agent: bad event: " .. line:sub(1, 80), vim.log.levels.WARN)
      end)
    end,
    on_exit = function(code)
      vim.schedule(function()
        pending_kind = nil
        ghost.clear()
        vim.notify("plan-agent: session exited (" .. code .. ")", vim.log.levels.WARN)
      end)
    end,
  })
  if not new_handle then
    vim.notify(err or "plan-agent: cannot start", vim.log.levels.ERROR)
    return false
  end
  handle = new_handle
  return true
end

--- Stop the session and clear pending state.
function M.stop()
  if timer then
    timer:stop()
    timer = nil
  end
  if handle then
    handle.stop()
    handle = nil
  end
  pending_kind = nil
  ghost.clear()
end

--- Route one decoded session event.
---@param event table
function M.on_event(event)
  if type(event) ~= "table" or type(event.type) ~= "string" then
    return
  end
  if event.type ~= "assistant" or type(event.content) ~= "string" then
    return
  end
  local kind = pending_kind
  local bufnr = pending_buf
  pending_kind = nil
  pending_buf = nil
  if kind == "suggest" then
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and is_enabled(bufnr) then
      ghost.show(bufnr, event.content)
    end
  elseif kind == "propose" then
    instruct.deliver(event.content)
  end
end

local function send(kind, content)
  if not M.start() then
    return false
  end
  pending_seq = pending_seq + 1
  ghost.clear()
  pending_kind = kind
  pending_buf = vim.api.nvim_get_current_buf()
  if not handle.send(content) then
    pending_kind = nil
    pending_buf = nil
    vim.notify("plan-agent: session is down", vim.log.levels.ERROR)
    return false
  end
  return true
end

--- Request a ghost completion at the cursor. No-op outside plan files.
---@return boolean sent
function M.suggest()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_enabled(bufnr) then
    return false
  end
  if instruct.busy() then
    return false
  end
  local anchor = vim.api.nvim_win_get_cursor(0)[1]
  return send("suggest", context.suggest_prompt(bufnr, anchor))
end

function M.schedule_suggest()
  if timer then
    timer:stop()
    timer = nil
  end
  ghost.clear()
  if not is_enabled(0) or instruct.busy() then
    return
  end
  timer = vim.defer_fn(function()
    timer = nil
    M.suggest()
  end, config.debounce_ms)
end

--- Accept the pending ghost. Returns true when a ghost was inserted,
--- so an expr <Tab> mapping can fall through otherwise.
---@return boolean accepted
function M.accept_ghost()
  if ghost.current() then
    local ok = ghost.accept()
    return ok
  end
  return false
end

--- Dismiss the pending ghost.
function M.dismiss_ghost()
  ghost.clear()
end

--- Open an anchored instruction at the cursor line.
function M.instruct_ask()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_enabled(bufnr) then
    vim.notify("plan-agent: not a plan file", vim.log.levels.WARN)
    return
  end
  if not M.start() then
    return
  end
  instruct.ask(function(content)
    return send("propose", content)
  end)
end

--- Plugin setup. Call once from your config.
---@param opts table|nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  local group = vim.api.nvim_create_augroup("plan_agent", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMovedI", "TextChangedI" }, {
    group = group,
    pattern = "*",
    callback = M.schedule_suggest,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = M.stop,
  })
  vim.api.nvim_create_user_command("PlanAgentStart", M.start, {})
  vim.api.nvim_create_user_command("PlanAgentStop", M.stop, {})
  vim.api.nvim_create_user_command("PlanAgentStatus", function()
    vim.notify("plan-agent: " .. M.status(), vim.log.levels.INFO)
  end, {})
  vim.api.nvim_create_user_command("PlanAgentSuggest", M.suggest, {})
  vim.api.nvim_create_user_command("PlanAgentInstruct", M.instruct_ask, {})
  -- Exposed for tests.
  M.enabled = is_enabled
  vim.api.nvim_create_user_command("PlanAgentEnable", function()
    vim.b.plan_agent_enabled = true
    vim.notify("plan-agent: enabled for this buffer", vim.log.levels.INFO)
  end, {})
  vim.api.nvim_create_user_command("PlanAgentDisable", function()
    vim.b.plan_agent_enabled = false
    M.dismiss_ghost()
    vim.notify("plan-agent: disabled for this buffer", vim.log.levels.INFO)
  end, {})
end

return M
