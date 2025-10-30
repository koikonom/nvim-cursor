## nvim-cursor-agent

Interactive `cursor-agent` CLI inside Neovim. Open a split next to your code and send selections or the entire buffer as context, then chat interactively in the terminal pane.

Reference: [Cursor CLI](https://cursor.com/cli)

### Install (vim-plug)

```vim
Plug 'kyriakos/nvim-cursor'
```

> If you named the repo differently, adjust the string accordingly.

### Setup

```lua
require('cursor_agent').setup({
  cmd = 'cursor-agent',
  args = {},
  split = 'vsplit',      -- 'vsplit' | 'split' | 'float'
  size = 0.35,           -- fraction or absolute
  reuse = 'tab',         -- 'tab' | 'global' | 'never'
  context_header = '[Context from Neovim]',
  bracketed_paste = true,        -- wrap payload in bracketed paste for faster TUI handling
  max_payload_bytes = 200000,    -- truncate very large payloads for responsiveness
  terminal_keymaps = true,       -- Esc exits terminal-mode; Ctrl-h/j/k/l move windows
  vsplit_side = 'right',         -- 'right' | 'left'
  split_side = 'bottom',         -- 'bottom' | 'top'
  kill_on_exit = true,           -- stop agent process when Neovim exits
})
```

### Commands

- `:CursorAgentOpen` — open/focus the interactive terminal running `cursor-agent`.
- `:[range]CursorAgentSend` — send the current line or a given range as context.
- `:CursorAgentSendBuffer` — send the entire buffer as context.
- `:CursorAgentClose` — close the terminal window.

### Suggested keymaps

**Recommended (Lua) - ensures visual selection is captured correctly:**

```lua
vim.keymap.set('n', '<leader>ca', '<cmd>CursorAgentOpen<CR>', {})
vim.keymap.set('x', '<leader>cs', function()
  local mod = require('cursor_agent')
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > 0 and end_line > 0 and start_line <= end_line then
    -- Call send_range directly to avoid any command parsing issues
    mod.send_range(start_line, end_line)
  end
end, {})
vim.keymap.set('n', '<leader>cb', '<cmd>CursorAgentSendBuffer<CR>', {})
```

**Alternative (Vimscript):**

```vim
nnoremap <leader>ca :CursorAgentOpen<CR>
xnoremap <leader>cs :CursorAgentSendVisual<CR>
nnoremap <leader>cb :CursorAgentSendBuffer<CR>
```

**Or using the command with range:**

```vim
xnoremap <leader>cs :<C-u>execute "CursorAgentSend"<CR>
```

Note: The Lua keymap is recommended as it ensures the visual selection range is properly captured and passed to the command.

### Notes

- Content is sent as a fenced code block with a configurable header, so the agent can treat it as context.
- Large pastes may take time; consider narrowing selections.
 - For performance, bracketed paste is enabled and payloads >200kB are truncated. Tune via `setup()`.
 - Quality-of-life: in the agent pane, press `Esc` to exit terminal-mode and `Ctrl-h/j/k/l` to navigate windows. Disable via `terminal_keymaps = false`.
 - Placement: use `vsplit_side = 'right'|'left'` and `split_side = 'bottom'|'top'` to control where the panel opens.
 - Cleanup: by default the plugin stops the `cursor-agent` job on `VimLeavePre`. Disable with `kill_on_exit = false` if you prefer to keep sessions alive.


