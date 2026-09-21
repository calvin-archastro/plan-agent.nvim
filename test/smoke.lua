-- plan-agent.nvim smoke test. Stock nvim only, no framework:
--   nvim --headless --noplugin -u NONE -l test/smoke.lua
local root = debug.getinfo(1, "S").source:match("^@(.*)/test/smoke%.lua$") or "."
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

local fails = 0
local function check(name, cond)
  if cond then
    print("ok: " .. name)
  else
    fails = fails + 1
    print("FAIL: " .. name)
  end
end

local session = require("plan-agent.session")
local ghost = require("plan-agent.ghost")
local context = require("plan-agent.context")
local instruct = require("plan-agent.instruct")
local pa = require("plan-agent.init")
local log = require("plan-agent.log")
check("modules load", session and ghost and context and instruct and pa and log)

-- ring log
log.enable_debug(false)
log.info("hello")
log.debug("silent")
check("info recorded", log.count() == 1)
log.enable_debug(true)
log.debug("loud")
check("debug gated", log.count() == 2)
for i = 1, 250 do
  log.info("fill " .. i)
end
check("ring truncates", log.count() == 200)
local formatted = log.lines()
check("lines format", #formatted == 200 and formatted[1]:find("fill 51", 1, true) ~= nil)
log.open()
local logbuf = vim.api.nvim_get_current_buf()
check(
  "log viewer",
  vim.api.nvim_buf_get_option(logbuf, "filetype") == "plan-agent-log"
    and #vim.api.nvim_buf_get_lines(logbuf, 0, -1, false) == 200
)
vim.api.nvim_buf_delete(logbuf, { force = true })

-- codec
check("encode", session.encode_message("hi") == '{"content":"hi"}')
local ev = session.decode_line('{"type":"assistant","content":"x"}')
check("decode", ev and ev.type == "assistant")
check("decode empty", session.decode_line("") == nil)
check("decode malformed", session.decode_line("{nope") == nil)

-- context on a real buffer
local buf = vim.api.nvim_create_buf(false, true)
local doc = {}
for i = 1, 40 do
  doc[i] = "line " .. i
end
vim.api.nvim_buf_set_lines(buf, 0, -1, false, doc)
vim.api.nvim_buf_set_name(buf, "/repo/docs/plans/2026-09-20-x.md")
local win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(win, buf)
local wlines, first = context.window(buf, 20, 10)
check("window size", #wlines == 21 and first == 10)
check("render", context.render({ "a", "b" }, 5) == "5: a\n6: b")
check(
  "suggest prompt",
  context.suggest_prompt(buf, 20):find("Cursor line: 20", 1, true) ~= nil
)
check(
  "propose prompt",
  context.propose_prompt(buf, 20, "expand it"):find("expand it", 1, true) ~= nil
)

-- ghost show/accept on a real window
vim.api.nvim_win_set_cursor(win, { 20, 0 })
check("ghost show", ghost.show(buf, "XX") == true)
check("ghost current", ghost.current() ~= nil)
check("ghost accept", ghost.accept() == true)
vim.wait(1000, function()
  return vim.api.nvim_buf_get_lines(buf, 19, 20, false)[1] == "XXline 20"
end)
check(
  "ghost text inserted",
  vim.api.nvim_buf_get_lines(buf, 19, 20, false)[1] == "XXline 20"
)
check("ghost cleared", ghost.current() == nil)
check("accept empty", ghost.accept() == false)

-- gating: paths config plus buffer-local enable/disable
pa.setup({ paths = { "docs/plans/" } })
local plans_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(plans_buf, "/repo/docs/plans/a.md")
local other_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(other_buf, "/repo/notes/b.md")
check("path match", pa.enabled(plans_buf) == true)
check("path miss", pa.enabled(other_buf) == false)
vim.api.nvim_buf_set_var(other_buf, "plan_agent_enabled", true)
check("buffer enable", pa.enabled(other_buf) == true)
vim.api.nvim_buf_set_var(plans_buf, "plan_agent_enabled", false)
check("buffer disable", pa.enabled(plans_buf) == false)

-- session argv shapes
pa.setup({ binary = "archdev" })
local cmd = pa.session_cmd()
check(
  "cmd string",
  cmd[1] == "archdev" and cmd[2] == "agents" and cmd[#cmd] == "--stream"
)
pa.setup({ binary = { "node", "/x/dist/index.js" } })
local cmd2 = pa.session_cmd()
check(
  "cmd list",
  cmd2[1] == "node" and cmd2[2] == "/x/dist/index.js" and cmd2[3] == "agents"
)

-- truncation predicate
check("truncated period", pa.truncated("ends complete.") == false)
check("truncated question", pa.truncated("really?") == false)
check("truncated colon", pa.truncated("item:") == false)
check("truncated hyphen", pa.truncated("mid-sent") == true)
check("truncated comma", pa.truncated("abc,") == true)
check("truncated empty", pa.truncated("  ") == true)
check("truncated paren", pa.truncated("(see") == true)

-- ga working marker (stubbed input and send: deterministic, no session)
local ga_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(ga_buf, "/repo/docs/plans/ga.md")
vim.api.nvim_buf_set_lines(ga_buf, 0, -1, false, { "a", "b" })
vim.api.nvim_win_set_buf(win, ga_buf)
vim.api.nvim_win_set_cursor(win, { 1, 0 })
local orig_input = vim.ui.input
vim.ui.input = function(_, cb)
  cb("expand it")
end
local sent_prompt = nil
instruct.ask(function(content)
  sent_prompt = content
  return true
end)
local anchor_ns = vim.api.nvim_create_namespace("plan_agent_anchor")
local function marker_text()
  local marks = vim.api.nvim_buf_get_extmarks(ga_buf, anchor_ns, 0, -1, { details = true })
  for _, m in ipairs(marks) do
    local vt = m[4] and m[4].virt_text
    if vt then
      return vt[1][1]
    end
  end
  return nil
end
check("working marker", marker_text() == "◌ agent working…")
instruct.working(150)
check(
  "working progress",
  (marker_text() or ""):find("150 chars", 1, true) ~= nil
)
check(
  "prompt built",
  sent_prompt ~= nil and sent_prompt:find("expand it", 1, true) ~= nil
)
-- sigil line inserted after the anchor
local sigil_line = vim.api.nvim_buf_get_lines(ga_buf, 1, 2, false)[1]
check(
  "sigil inserted",
  sigil_line:find("plan-agent:", 1, true) ~= nil
    and sigil_line:find("expand it", 1, true) ~= nil
)
check("instruction busy", instruct.busy() == true)
-- deliver expands the sigil in place
instruct.deliver("p1\np2")
local expanded = vim.api.nvim_buf_get_lines(ga_buf, 0, -1, false)
check(
  "sigil expanded",
  #expanded == 4 and expanded[2] == "p1" and expanded[3] == "p2"
)
check("instruction idle", instruct.busy() == false)
-- deleting the sigil vetoes the job
vim.api.nvim_win_set_cursor(win, { 1, 0 })
instruct.ask(function(_)
  return true
end)
vim.api.nvim_buf_set_lines(ga_buf, 1, 2, false, {})
instruct.deliver("zzz")
local vetoed = vim.api.nvim_buf_get_lines(ga_buf, 0, -1, false)
check(
  "sigil veto",
  #vetoed == 4 and vetoed[2] == "p1" and instruct.busy() == false
)
vim.ui.input = orig_input

-- live session round-trip against the fake binary
local got_events = {}
local h, err = session.start({
  cmd = { root .. "/test/fake-archdev.py" },
  on_event = function(e)
    got_events[#got_events + 1] = e
  end,
})
check("session spawns", h ~= nil and err == nil)
check("session send", h.send("hello world") == true)
vim.wait(2000, function()
  return #got_events > 0
end)
check(
  "round trip",
  #got_events == 1
    and got_events[1].type == "assistant"
    and got_events[1].content:find("echo", 1, true) ~= nil
)
h.stop()
check("session stopped", h.running() == false)

-- continuation: fake replies end in digits (truncated), so one suggest
-- must chain a "continue" and append both turns into one ghost
pa.setup({ binary = root .. "/test/fake-archdev.py", max_continuations = 1 })
local cont_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(cont_buf, "/repo/docs/plans/cont.md")
vim.api.nvim_buf_set_lines(cont_buf, 0, -1, false, { "hello" })
vim.api.nvim_win_set_buf(win, cont_buf)
vim.api.nvim_win_set_cursor(win, { 1, 5 })
check("continuation suggest sent", pa.suggest() == true)
vim.wait(5000, function()
  local g = ghost.current()
  return g ~= nil and select(2, g.text:gsub("echo", "")) == 2
end)
local chained = ghost.current()
check(
  "continuation appended",
  chained ~= nil and select(2, chained.text:gsub("echo", "")) == 2
)
pa.stop()

if fails == 0 then
  print("ALL PASS")
  vim.cmd("quit!")
else
  print("FAILURES: " .. fails)
  vim.cmd("cquit!")
end
