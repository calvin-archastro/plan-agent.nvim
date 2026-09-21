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
| `binary` | `"archdev"` | CLI on PATH |
| `model` | `nil` | `--model` for the session |
| `permission_mode` | `"deny"` | tool-free session: text proposals only |
| `debounce_ms` | `350` | idle delay before requesting a ghost |
| `prompt` | co-editing brief | standing `--print` prompt (required by `--stream`) |
| `paths` | `{ "docs/plans/" }` | enabled when the buffer path contains any entry (plain substring, not repo-root-relative) |

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
   moving on or a new request dismisses.
2. **Instruction** (`ga` / `:PlanAgentInstruct`): type a note at the cursor
   line → proposal opens in a split → `<CR>` applies it after the anchor
   (one undo block), `q` rejects.
3. The anchor is an extmark: edits above it don't detach the proposal.

## Enabling other files

Two ways, combinable:

1. Directories: `require("plan-agent").setup({ paths = { "docs/plans/", "my/notes/" } })`
2. One file: `:PlanAgentEnable` opts the current buffer in, `:PlanAgentDisable` opts it out (buffer-local, beats path matching)

## Commands

`:PlanAgentStart :PlanAgentStop :PlanAgentStatus :PlanAgentSuggest :PlanAgentInstruct :PlanAgentEnable :PlanAgentDisable`

## Tests

Stock nvim only: `nvim --headless --noplugin -u NONE -l test/smoke.lua`
