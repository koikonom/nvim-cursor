local mod = require('cursor_agent')

vim.api.nvim_create_user_command('CursorAgentOpen', function()
  mod.open()
end, { desc = 'Open or focus cursor-agent terminal' })

vim.api.nvim_create_user_command('CursorAgentClose', function()
  mod.close()
end, { desc = 'Close cursor-agent terminal if open' })

-- Function to send visual selection (can be called directly from keymap)
local function send_visual_selection()
  mod.send_visual()
end

vim.api.nvim_create_user_command('CursorAgentSend', function(opts)
  -- Prioritize explicit range from opts (most reliable when provided via :5,10CursorAgentSend)
  if opts.range ~= 0 and opts.line1 and opts.line2 then
    -- Use the explicit range from opts (for ranges like :10,20CursorAgentSend)
    mod.send_range(opts.line1, opts.line2)
  else
    -- Fallback: check visual marks (for when called from visual mode without explicit range)
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    local current_buf = vim.api.nvim_get_current_buf()
    
    -- Check if we have valid visual marks in the current buffer
    local has_visual_marks = start_pos[2] > 0 and end_pos[2] > 0 
                             and start_pos[1] == current_buf and end_pos[1] == current_buf
    
    if has_visual_marks then
      -- Use visual marks which handle visual selections properly
      mod.send_visual()
    else
      -- Default to current line
      mod.send_range(vim.fn.line('.'), vim.fn.line('.'))
    end
  end
end, {
  desc = 'Send current line or [range] as context to cursor-agent',
  range = true,
})

-- Export function for direct keymap usage
vim.api.nvim_create_user_command('CursorAgentSendVisual', function()
  mod.send_visual()
end, { desc = 'Send visual selection as context to cursor-agent' })

-- Lua function for visual mode keymap that captures selection immediately
local function send_visual_selection_lua()
  local bufnr = vim.api.nvim_get_current_buf()
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  
  -- Validate we have a valid selection
  if start_line > 0 and end_line > 0 and start_line <= end_line then
    mod.send_range(start_line, end_line)
  else
    -- Fallback to send_visual
    mod.send_visual()
  end
end

-- Make it available as a command too
vim.api.nvim_create_user_command('CursorAgentSendVisualRange', function()
  send_visual_selection_lua()
end, { desc = 'Send visual selection using range marks' })

vim.api.nvim_create_user_command('CursorAgentSendBuffer', function()
  mod.send_buffer()
end, { desc = 'Send entire buffer as context to cursor-agent' })


