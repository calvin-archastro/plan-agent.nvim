--- plan-agent: background archdev sidecar for co-editing docs/plans.
--- Ghost completions via Tab, anchored instructions via g a.
--- The agent proposes; only your keypress writes the buffer.
local session = require("plan-agent.session")
local log = require("plan-agent.log")
local ghost = require("plan-agent.ghost")
local context = require("plan-agent.context")
local instruct = require("plan-agent.instruct")

local M = {}

local defaults = {
  -- String binary on PATH, or argv prefix list for dev builds, e.g.
  -- {"node", "/path/to/src/ts/archdev/dist/index.js"}.
  binary = "archdev",
  model = nil,
  permission_mode = "deny",
  debounce_ms = 350,
  -- Enabled when the buffer path contains any entry (plain substring).
  paths = { "docs/plans/" },
  -- Verbose ring-log entries (event flow, triggers, skips).
  debug = false,
  prompt = "You co-edit a Markdown plan beside the user. "
    .. "Reply with ONLY the requested text: no fences, no explanation. "
    .. "Always finish the thought; never trail off mid-sentence.",
  -- Auto-continue a ghost that arrives truncated, at most this many extra
  -- turns per request.
  max_continuations = 2,
}

local config = vim.deepcopy(defaults)
---@type table|nil session handle from session.start
local handle = nil
local pending_kind = nil ---@type "suggest"|"propose"|"pass"|nil
local pass_snapshot = nil ---@type string|nil buffer text at pass send
local pending_buf = nil ---@type number|nil
local pending_pos = nil ---@type { row: integer, col: integer }|nil
local pending_seq = 0
local continuations = 0
local propose_chars = 0
local snapshots = {} ---@type table<number, string>
local timer = nil
local last_stderr = {} ---@type string[]

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

--- Diff the buffer against its last-sent snapshot (unified hunks the
--- model reads directly), then store the new snapshot. Empty on first
--- send or when nothing changed. Exposed for tests.
---@param bufnr number
---@return string
function M.snapshot_diff(bufnr)
  local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local prev = snapshots[bufnr]
  snapshots[bufnr] = text
  if not prev or prev == text then
    return ""
  end
  local ok, diff = pcall(vim.diff, prev, text, { result_type = "unified" })
  if not ok or type(diff) ~= "string" or diff == "" then
    return ""
  end
  if #diff > 4000 then
    diff = diff:sub(1, 4000) .. "\n[... diff truncated ...]"
  end
  return diff
end

--- Build the session argv from config. Exposed for tests.
---@return string[]
function M.session_cmd()
  local cmd = {}
  if type(config.binary) == "table" then
    for _, part in ipairs(config.binary) do
      cmd[#cmd + 1] = part
    end
  else
    cmd[#cmd + 1] = config.binary
  end
  vim.list_extend(cmd, { "agents", "run", config.prompt, "--stream" })
  return cmd
end

--- Start the persistent session. Idempotent.
---@return boolean
function M.start()
  if handle and handle.running() then
    return true
  end
  M.stop()
  local cmd = M.session_cmd()
  if config.model then
    vim.list_extend(cmd, { "--model", config.model })
  end
  if config.permission_mode then
    vim.list_extend(cmd, { "--permission-mode", config.permission_mode })
  end
  last_stderr = {}
  log.info("start: " .. table.concat(cmd, " "))
  local new_handle, err = session.start({
    cmd = cmd,
    on_event = function(event)
      log.debug(
        "event: " .. tostring(event.type) .. " len=" .. #tostring(event.content or "")
      )
      vim.schedule(function()
        M.on_event(event)
      end)
    end,
    on_stderr = function(lines)
      for _, line in ipairs(lines) do
        last_stderr[#last_stderr + 1] = line
        if #last_stderr > 3 then
          table.remove(last_stderr, 1)
        end
      end
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
        -- Clean completion exits are routine (the headless run ends with
        -- its answer); only abnormal exits notify, with stderr attached.
        if code ~= 0 then
          local detail = table.concat(last_stderr, " "):sub(1, 160)
          vim.notify(
            "plan-agent: session exited (" .. code .. ") " .. detail,
            vim.log.levels.ERROR
          )
        end
      end)
    end,
  })
  if not new_handle then
    log.error("spawn failed: " .. (err or "unknown"))
    vim.notify(err or "plan-agent: cannot start", vim.log.levels.ERROR)
    return false
  end
  handle = new_handle
  log.info("session running")
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
  pending_buf = nil
  pending_pos = nil
  pass_snapshot = nil
  continuations = 0
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
  -- Streaming progress for an open instruction; the pending request stays.
  if
    kind == "propose"
    and (event.type == "assistant_delta" or event.type == "assistant_thinking_delta")
    and type(event.delta) == "string"
  then
    propose_chars = propose_chars + #event.delta
    instruct.working(propose_chars)
    return
  end
  if event.type == "assistant_restart" then
    propose_chars = 0
    return
  end
  if kind == "suggest" then
    -- Paint first, then decide: a truncated ghost stays open and extends.
    if
      bufnr
      and vim.api.nvim_buf_is_valid(bufnr)
      and bufnr == vim.api.nvim_get_current_buf()
      and is_enabled(bufnr)
    then
      local shown = ghost.current()
      local text = event.content
      if shown and shown.bufnr == bufnr then
        text = shown.text .. text
      end
      ghost.show(bufnr, text, pending_pos)
      if
        M.truncated(event.content)
        and continuations < config.max_continuations
        and handle
        and handle.running()
      then
        continuations = continuations + 1
        log.debug("ghost truncated, continuing (" .. continuations .. ")")
        -- pending_kind/pending_buf stay: the next event appends.
        handle.send("continue")
        return
      end
    end
    pending_kind = nil
    pending_buf = nil
    pending_pos = nil
    continuations = 0
  else
    pending_kind = nil
    pending_buf = nil
    pending_pos = nil
    continuations = 0
    if kind == "propose" then
      instruct.deliver(event.content)
    elseif kind == "pass" then
      M.deliver_pass(bufnr, event.content, pass_snapshot)
      pass_snapshot = nil
    end
  end
end

--- Truncated when the trimmed text ends mid-thought rather than on a
--- sentence boundary. Exposed for tests.
---@param text string
---@return boolean
function M.truncated(text)
  local trimmed = text:gsub("%s+$", "")
  if trimmed == "" then
    return true
  end
  local last = trimmed:sub(-1)
  return last:match("[%w,–—(/%-]") ~= nil
end

local function send(kind, content)
  if not M.start() then
    return false
  end
  pending_seq = pending_seq + 1
  ghost.clear()
  pending_kind = kind
  pending_buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  pending_pos = { row = cursor[1] - 1, col = cursor[2] }
  continuations = 0
  propose_chars = 0
  log.debug("send: kind=" .. kind .. " bytes=" .. #content)
  log.debug("send head: " .. content:sub(1, 200):gsub("\n", "\\n"))
  if not handle.send(content) then
    log.error("send failed: session is down")
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
    log.debug("suggest skip: buffer not enabled")
    return false
  end
  if instruct.busy() then
    log.debug("suggest skip: instruction busy")
    return false
  end
  local anchor = vim.api.nvim_win_get_cursor(0)[1]
  return send("suggest", context.suggest_prompt(bufnr, anchor, M.snapshot_diff(bufnr)))
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
    vim.notify("plan-agent: not enabled here (:PlanAgentEnable)", vim.log.levels.WARN)
    return
  end
  if not M.start() then
    return
  end
  instruct.ask(function(content)
    return send("propose", content)
  end, {
    diff_fn = function(buf)
      return M.snapshot_diff(buf)
    end,
  })
end

--- Last visual selection as a 0-indexed [start, exclusive end) range.
--- Whole lines; a charwise selection rounds out. Uses the '< and '> marks:
--- an x-mode Lua mapping runs after visual mode has already exited, so
--- mode()/getpos("v") can no longer see the selection. Nil when no marks.
---@return { srow: integer, erow: integer }|nil
function M.visual_range()
  local start_line = vim.fn.getpos("'<")[2]
  local end_line = vim.fn.getpos("'>")[2]
  if start_line == 0 or end_line == 0 then
    return nil
  end
  return {
    srow = math.min(start_line, end_line) - 1,
    erow = math.max(start_line, end_line),
  }
end

--- Open an instruction rewriting the visual selection (possibly to nothing).
function M.instruct_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_enabled(bufnr) then
    vim.notify("plan-agent: not enabled here (:PlanAgentEnable)", vim.log.levels.WARN)
    return
  end
  local sm = vim.fn.getpos("'<")
  local em = vim.fn.getpos("'>")
  log.info(
    string.format(
      "visual: mode=%s bufnr=%d '<=%d:%d '>=%d:%d",
      vim.fn.mode(),
      bufnr,
      sm[1],
      sm[2],
      em[1],
      em[2]
    )
  )
  local range = M.visual_range()
  if not range then
    vim.notify("plan-agent: no selection", vim.log.levels.WARN)
    return
  end
  if not M.start() then
    return
  end
  instruct.ask(function(content)
    return send("propose", content)
  end, {
    range = range,
    diff_fn = function(buf)
      return M.snapshot_diff(buf)
    end,
  })
end

--- Apply a whole-document pass result. Drops (buffer untouched) when the
--- reply is chatty, when the buffer changed since the pass started, or
--- when the reply is empty. Snapshot is passed in so tests can drive this
--- directly. Exposed for tests.
---@param bufnr number|nil
---@param text string
---@param snapshot string|nil buffer text at send time
function M.deliver_pass(bufnr, text, snapshot)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if instruct.chatty(text) then
    log.info("pass dropped: chatty reply")
    vim.notify(
      "plan-agent: agent asked for clarification, pass dropped",
      vim.log.levels.WARN
    )
    return
  end
  local current =
    table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  if snapshot and current ~= snapshot then
    log.info("pass dropped: buffer changed mid-pass")
    vim.notify(
      "plan-agent: buffer changed during pass, dropped (rerun gA)",
      vim.log.levels.WARN
    )
    return
  end
  local lines = vim.split(text, "\n", { plain = true })
  while #lines > 0 and lines[#lines] == "" do
    lines[#lines] = nil
  end
  if #lines == 0 then
    log.info("pass: empty reply, no changes")
    vim.notify("plan-agent: pass made no changes", vim.log.levels.INFO)
    return
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  log.info("pass applied: " .. #lines .. " lines")
  vim.notify("plan-agent: pass applied (u to undo)", vim.log.levels.INFO)
end

--- Whole-document editing pass. Optional instruction arg; otherwise prompts.
--- The buffer snapshot guards against clobbering your typing mid-pass.
---@param instruction string|nil
function M.pass_ask(instruction)
  local bufnr = vim.api.nvim_get_current_buf()
  if not is_enabled(bufnr) then
    vim.notify("plan-agent: not enabled here (:PlanAgentEnable)", vim.log.levels.WARN)
    return
  end
  local function go(instr)
    if instr == nil or instr == "" then
      return
    end
    pass_snapshot =
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    if not send("pass", context.pass_prompt(bufnr, instr, M.snapshot_diff(bufnr))) then
      pass_snapshot = nil
    end
  end
  if instruction and instruction ~= "" then
    go(instruction)
  else
    vim.ui.input({ prompt = "@agent pass " }, go)
  end
end

--- Plugin setup. Call once from your config.
---@param opts table|nil
function M.setup(opts)
  config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  log.enable_debug(config.debug == true)
  log.info("setup: debug=" .. tostring(config.debug == true))
  pcall(function()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local root = vim.fn.fnamemodify(src, ":h:h:h")
    local rev = vim.fn.system({ "git", "-C", root, "rev-parse", "--short", "HEAD" })
    log.info("setup: src=" .. src .. " rev=" .. tostring(rev):gsub("%s+", ""))
  end)
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
  vim.api.nvim_create_user_command("PlanAgentStart", M.start, { force = true })
  vim.api.nvim_create_user_command("PlanAgentStop", M.stop, { force = true })
  vim.api.nvim_create_user_command("PlanAgentStatus", function()
    vim.notify("plan-agent: " .. M.status(), vim.log.levels.INFO)
  end, { force = true })
  vim.api.nvim_create_user_command("PlanAgentSuggest", M.suggest, { force = true })
  vim.api.nvim_create_user_command("PlanAgentInstruct", M.instruct_ask, { force = true })
  vim.api.nvim_create_user_command("PlanAgentVisual", M.instruct_visual, { force = true })
  vim.api.nvim_create_user_command("PlanAgentPass", function(opts)
    M.pass_ask(opts.args ~= "" and opts.args or nil)
  end, { force = true, nargs = "?" })
  vim.api.nvim_create_user_command("PlanAgentLog", function()
    log.open()
  end, { force = true })
  -- Exposed for tests.
  M.enabled = is_enabled
  vim.api.nvim_create_user_command("PlanAgentEnable", function()
    vim.b.plan_agent_enabled = true
    vim.notify("plan-agent: enabled for this buffer", vim.log.levels.INFO)
  end, { force = true })
  vim.api.nvim_create_user_command("PlanAgentDisable", function()
    vim.b.plan_agent_enabled = false
    M.dismiss_ghost()
    vim.notify("plan-agent: disabled for this buffer", vim.log.levels.INFO)
  end, { force = true })
end

return M
