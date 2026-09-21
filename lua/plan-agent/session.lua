--- plan-agent.session: one persistent `archdev agents run --stream` process.
--- Stdout NDJSON events in, steering messages out. No ports or tokens.
local M = {}

--- Encode one steering message for stdin.
---@param content string
---@return string line without trailing newline
function M.encode_message(content)
  return vim.json.encode({ content = content })
end

--- Decode one stdout line. Returns event table, or nil plus reason.
---@param line string
---@return table|nil, string|nil
function M.decode_line(line)
  if line == "" then
    return nil, "empty"
  end
  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= "table" then
    return nil, "malformed"
  end
  return event, nil
end

---@class PlanAgentSessionOpts
---@field cmd string[] full argv, e.g. {"archdev","agents","run","prompt","--stream"}
---@field on_event fun(event: table) every decoded stdout event
---@field on_malformed? fun(line: string) undecodable stdout lines
---@field on_stderr? fun(lines: string[]) raw stderr chunks
---@field on_exit? fun(code: number) process end

--- Spawn the session. Returns a handle, or nil plus error on spawn failure.
---@param opts PlanAgentSessionOpts
function M.start(opts)
  -- Nvim splits job output on newlines before delivery: every element but
  -- the last is a complete line, the last is a fragment to carry over.
  local pending = ""
  local handle = { job = nil }
  local function emit(line)
    if line == "" then
      return
    end
    local event, reason = M.decode_line(line)
    if event then
      opts.on_event(event)
    elseif reason == "malformed" and opts.on_malformed then
      opts.on_malformed(line)
    end
  end
  local job = vim.fn.jobstart(opts.cmd, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data, _)
      for i, chunk in ipairs(data) do
        if i < #data then
          emit(pending .. chunk)
          pending = ""
        else
          pending = pending .. chunk
        end
      end
    end,
    on_stderr = function(_, data, _)
      if opts.on_stderr and not (data == nil or (#data == 1 and data[1] == "")) then
        opts.on_stderr(data)
      end
    end,
    on_exit = function(_, code, _)
      handle.job = nil
      if pending ~= "" then
        local line = pending
        pending = ""
        emit(line)
      end
      if opts.on_exit then
        opts.on_exit(code)
      end
    end,
  })
  if job <= 0 then
    return nil, "plan-agent: failed to spawn " .. table.concat(opts.cmd, " ")
  end
  handle.job = job

  --- Send one steering message. Returns false when the session is down.
  ---@param content string
  ---@return boolean
  function handle.send(content)
    if not handle.job then
      return false
    end
    return vim.fn.chansend(handle.job, M.encode_message(content) .. "\n") > 0
  end

  --- Stop the session. Safe to call twice.
  function handle.stop()
    if handle.job then
      vim.fn.jobstop(handle.job)
      handle.job = nil
    end
  end

  --- True while the process is alive.
  ---@return boolean
  function handle.running()
    return handle.job ~= nil
  end

  return handle, nil
end

return M
