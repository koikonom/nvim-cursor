local mod = require('cursor_agent')

vim.api.nvim_create_user_command('CursorAgentOpen', function()
  mod.open()
end, { desc = 'Open or focus cursor-agent terminal' })

vim.api.nvim_create_user_command('CursorAgentClose', function()
  mod.close()
end, { desc = 'Close cursor-agent terminal if open' })

vim.api.nvim_create_user_command('CursorAgentSend', function(opts)
  if opts.range == 0 then
    mod.send_range(vim.fn.line('.'), vim.fn.line('.'))
  else
    mod.send_range(opts.line1, opts.line2)
  end
end, {
  desc = 'Send current line or [range] as context to cursor-agent',
  range = true,
})

vim.api.nvim_create_user_command('CursorAgentSendBuffer', function()
  mod.send_buffer()
end, { desc = 'Send entire buffer as context to cursor-agent' })


