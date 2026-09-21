# plan-agent.nvim

Background [archdev](../..) sidecar for co-editing `docs/plans/*.md`.
One persistent `agents run --stream` session per nvim instance; the agent
proposes, only your keypress writes the buffer.

## Setup

```lua
-- lazy.nvim
{ dir = "tools/nvim-plan-agent", config = function()
  require("plan-agent").setup({ model = "platform/my-fast-model" })
end }
```

`setup(opts)` — all optional:

| key | default | meaning |
| --- | ------- | ------- |
| `binary` | `"archdev"` | CLI on PATH, or argv-prefix list for dev builds: `{"node", "…/dist/index.js"}` |
| `model` | `nil` | `--model` for the session |
| `permission_mode` | `"deny"` | tool-free session: text proposals only |
| `debounce_ms` | `350` | idle delay before requesting a ghost |
| `prompt` | co-editing brief | standing `--print` prompt (required by `--stream`) |
| `paths` | `{ "docs/plans/" }` | enabled when the buffer path contains any entry (plain substring, not repo-root-relative) |
| `debug` | `false` | verbose ring-log entries (event flow, triggers, skips) |

Suggested keymaps:

```lua
vim.keymap.set("i", "<Tab>", function()
  if require("plan-agent").accept_ghost() then return "" end
  return vim.api.nvim_replace_termcodes("<Tab>", true, false, true)
end, { expr = true })
vim.keymap.set("n", "ga", function() require("plan-agent").instruct_ask() end)
```

Add `%{v:lua.require'plan-agent'.status()}` to your statusline for
`PA:idle | PA:working | PA:proposal | PA:down`.

## Flows

1. **Ghost**: pause in a plan file → grey inline text → `<Tab>` inserts,
   moving on or a new request dismisses. A ghost that arrives mid-thought
   keeps streaming: it paints immediately, sends `continue` itself (up to
   `max_continuations = 2`), and extends in place.
2. **Instruction** (`ga` / `:PlanAgentInstruct`): type a note at the cursor
   line → a sigil line appears (`<!-- ◌ plan-agent:<id> … -->`) with a live
   char count while the agent works → the sigil expands into the proposal
   in place (one undo block, `u` reverts). Delete the sigil and the result
   is dropped. No windows open; keep writing anywhere meanwhile.
3. The anchor is an extmark: edits above it don't detach the proposal.

## Enabling other files

Two ways, combinable:

1. Directories: `require("plan-agent").setup({ paths = { "docs/plans/", "my/notes/" } })`
2. One file: `:PlanAgentEnable` opts the current buffer in, `:PlanAgentDisable` opts it out (buffer-local, beats path matching)

## Commands

`:PlanAgentStart :PlanAgentStop :PlanAgentStatus :PlanAgentSuggest :PlanAgentInstruct :PlanAgentEnable :PlanAgentDisable :PlanAgentLog`

## Diagnosing

`:PlanAgentLog` opens the ring log (last 200 entries): session spawns with
full argv, sends, event types, ghost renders, instruction lifecycle, exit
codes with stderr attached. For the full firehose (every event, trigger,
skip reason), `setup({ debug = true })`. Next time something fails, paste
the log — no more guessing.

## Tests

Stock nvim only: `nvim --headless --noplugin -u NONE -l test/smoke.lua`
