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
check("modules load", session and ghost and context and instruct and pa)

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

-- instruct deliver/accept/reject
vim.api.nvim_win_set_cursor(win, { 10, 0 })
instruct.deliver("new line one\nnew line two")
check("proposal busy", instruct.busy() == true)
check("proposal accept", instruct.accept() == true)
local after = vim.api.nvim_buf_get_lines(buf, 10, 12, false)
check("proposal applied", after[1] == "new line one" and after[2] == "new line two")
check("proposal idle", instruct.busy() == false)
instruct.deliver("reject me")
instruct.reject()
check("proposal rejected", instruct.busy() == false)

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

if fails == 0 then
  print("ALL PASS")
  vim.cmd("quit!")
else
  print("FAILURES: " .. fails)
  vim.cmd("cquit!")
end
