local M = {}

local default_config = {
  cmd = "cursor-agent",
  args = {},
  split = "vsplit", -- "vsplit" | "split" | "float"
  size = 0.35, -- fraction or absolute size
  reuse = "tab", -- "tab" | "global" | "never"
  context_header = "[Context from Neovim]",
  bracketed_paste = true,
  max_payload_bytes = 200000, -- truncate very large payloads for responsiveness
  terminal_keymaps = true, -- provide convenient terminal-mode maps
  vsplit_side = "right", -- "right" | "left"
  split_side = "bottom", -- "bottom" | "top"
  kill_on_exit = true, -- stop agent processes on Neovim exit
}

local state = {
  config = nil,
  global = { job_id = nil, term_bufnr = nil, win_id = nil },
  per_tab = {},
}

local function get_config()
  if not state.config then
    state.config = vim.tbl_deep_extend("force", {}, default_config)
  end
  return state.config
end

local function current_tab_state()
  local tab = vim.api.nvim_get_current_tabpage()
  state.per_tab[tab] = state.per_tab[tab] or { job_id = nil, term_bufnr = nil, win_id = nil }
  return state.per_tab[tab]
end

local function get_active_holder()
  local cfg = get_config()
  if cfg.reuse == "global" then
    return state.global
  elseif cfg.reuse == "tab" then
    return current_tab_state()
  else
    -- never reuse: use a fresh holder each call
    return { job_id = nil, term_bufnr = nil, win_id = nil }
  end
end

local function set_active_holder(holder)
  local cfg = get_config()
  if cfg.reuse == "global" then
    state.global = holder
  elseif cfg.reuse == "tab" then
    local tab = vim.api.nvim_get_current_tabpage()
    state.per_tab[tab] = holder
  end
end

local function compute_size(split_kind, size)
  if type(size) ~= "number" then return nil end
  if split_kind == "vsplit" then
    local columns = vim.o.columns
    if size > 0 and size < 1 then
      return math.max(20, math.floor(columns * size))
    end
    return math.max(20, math.floor(size))
  else
    local lines = vim.o.lines - vim.o.cmdheight
    if size > 0 and size < 1 then
      return math.max(5, math.floor(lines * size))
    end
    return math.max(5, math.floor(size))
  end
end

local function ensure_window_for_term(split_kind, size)
  local cfg = get_config()
  if split_kind == "float" then
    local width = compute_size("vsplit", size) or math.floor(vim.o.columns * 0.5)
    local height = compute_size("split", size) or math.floor((vim.o.lines - vim.o.cmdheight) * 0.5)
    local row = math.floor(((vim.o.lines - vim.o.cmdheight) - height) / 2)
    local col = math.floor((vim.o.columns - width) / 2)
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      border = "single",
      style = "minimal",
    })
    return buf, win
  elseif split_kind == "vsplit" then
    local prev = vim.o.splitright
    if cfg.vsplit_side == "right" then
      vim.o.splitright = true
    else
      vim.o.splitright = false
    end
    vim.cmd("vsplit")
    local win = vim.api.nvim_get_current_win()
    local w = compute_size("vsplit", size)
    if w then vim.api.nvim_win_set_width(win, w) end
    local term_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(term_buf, "buflisted", false)
    vim.api.nvim_win_set_buf(win, term_buf)
    vim.o.splitright = prev
    return term_buf, win
  else
    local prev = vim.o.splitbelow
    if cfg.split_side == "bottom" then
      vim.o.splitbelow = true
    else
      vim.o.splitbelow = false
    end
    vim.cmd("split")
    local win = vim.api.nvim_get_current_win()
    local h = compute_size("split", size)
    if h then vim.api.nvim_win_set_height(win, h) end
    local term_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(term_buf, "buflisted", false)
    vim.api.nvim_win_set_buf(win, term_buf)
    vim.o.splitbelow = prev
    return term_buf, win
  end
end

local function apply_terminal_keymaps(bufnr)
  local cfg = get_config()
  if not cfg.terminal_keymaps then return end
  local opts = { noremap = true, silent = true, buffer = bufnr }
  -- Quick exit from terminal-mode
  vim.keymap.set('t', '<Esc>', [[<C-\><C-n>]], opts)
  -- Window navigation from terminal-mode
  vim.keymap.set('t', '<C-h>', [[<C-\><C-n><C-w>h]], opts)
  vim.keymap.set('t', '<C-j>', [[<C-\><C-n><C-w>j]], opts)
  vim.keymap.set('t', '<C-k>', [[<C-\><C-n><C-w>k]], opts)
  vim.keymap.set('t', '<C-l>', [[<C-\><C-n><C-w>l]], opts)
end

local function is_job_alive(job_id)
  if not job_id then return false end
  local ok, r = pcall(vim.fn.jobwait, { job_id }, 0)
  if not ok then return false end
  -- jobwait returns -1 if still running
  return r and r[1] == -1
end

local function stop_holder(holder)
  if not holder then return end
  
  -- Stop the job/process forcefully
  if holder.job_id then
    -- Try graceful interrupt first (Ctrl-C)
    pcall(vim.api.nvim_chan_send, holder.job_id, "\003")
    
    -- Force stop - use jobstop which sends SIGTERM/SIGKILL
    -- Don't wait, just stop immediately and let OS handle cleanup
    pcall(vim.fn.jobstop, holder.job_id)
    
    -- Also try to get process info and kill if needed (more aggressive)
    local ok, job_info = pcall(vim.fn.job_info, holder.job_id)
    if ok and job_info and job_info.process then
      -- If we have process info, we could kill it directly, but jobstop should be enough
      -- For now, just ensure jobstop was called
    end
  end
  
  -- Close window if valid (this also helps cleanup)
  if holder.win_id and vim.api.nvim_win_is_valid(holder.win_id) then
    pcall(vim.api.nvim_win_close, holder.win_id, true)
  end
  
  -- Clear holder state to prevent reuse
  holder.job_id = nil
  holder.term_bufnr = nil
  holder.win_id = nil
end

local function start_terminal()
  local cfg = get_config()
  local holder = get_active_holder()

  if holder.term_bufnr and holder.job_id and is_job_alive(holder.job_id) then
    if holder.win_id and vim.api.nvim_win_is_valid(holder.win_id) then
      vim.api.nvim_set_current_win(holder.win_id)
      vim.cmd('startinsert')
    else
      -- reopen a window for the existing terminal buffer
      local _, win = ensure_window_for_term(cfg.split, cfg.size)
      vim.api.nvim_win_set_buf(win, holder.term_bufnr)
      holder.win_id = win
      set_active_holder(holder)
      vim.cmd('startinsert')
    end
    if holder.term_bufnr then apply_terminal_keymaps(holder.term_bufnr) end
    return holder
  end

  local buf, win = ensure_window_for_term(cfg.split, cfg.size)
  local cmd = { cfg.cmd }
  for _, a in ipairs(cfg.args or {}) do table.insert(cmd, a) end

  -- Use termopen with detach=false to ensure process terminates with Neovim
  -- Also ensure we can properly stop the job
  local job_id = vim.fn.termopen(cmd, {
    cwd = vim.loop.cwd(),
    detach = false,  -- Process should terminate when Neovim exits
  })
  vim.api.nvim_buf_set_option(buf, "buflisted", false)
  vim.api.nvim_set_current_win(win)
  vim.cmd('startinsert')
  apply_terminal_keymaps(buf)

  holder = { job_id = job_id, term_bufnr = buf, win_id = win }
  set_active_holder(holder)
  return holder
end

local function ensure_session()
  local holder = get_active_holder()
  if not holder.job_id or not is_job_alive(holder.job_id) then
    holder = start_terminal()
  else
    if holder.win_id and vim.api.nvim_win_is_valid(holder.win_id) then
      vim.api.nvim_set_current_win(holder.win_id)
      vim.cmd('startinsert')
    end
  end
  return holder
end

local function truncate_bytes(s, max_bytes)
  if not max_bytes or max_bytes <= 0 then return s, 0 end
  if #s <= max_bytes then return s, 0 end
  local truncated = string.sub(s, 1, max_bytes)
  local omitted = #s - max_bytes
  return truncated, omitted
end

local function build_file_reference(filepath, start_line, end_line)
  -- Build @file reference, optionally with line range
  -- filepath: absolute or relative path to file
  -- start_line, end_line: 1-based line numbers (nil for entire file)
  local ref = "@" .. filepath
  if start_line and end_line and start_line ~= end_line then
    ref = string.format("%s:%d-%d", ref, start_line, end_line)
  elseif start_line and end_line and start_line == end_line then
    ref = string.format("%s:%d", ref, start_line)
  end
  return ref
end

local function build_payload(lines, filetype)
  local cfg = get_config()
  local header = cfg.context_header or "[Context from Neovim]"
  local ft = (filetype and #filetype > 0) and filetype or ""
  local body = table.concat(lines, "\n")
  local fenced_open = ft ~= "" and ("```" .. ft) or "```"
  local payload_body, omitted = truncate_bytes(body, cfg.max_payload_bytes)
  if omitted > 0 then
    header = string.format("%s (truncated, omitted %d bytes)", header, omitted)
  end
  local payload = table.concat({ header, fenced_open, payload_body, "```", "" }, "\n")
  return payload
end

local function send_text(payload)
  local holder = ensure_session()
  if not holder or not holder.job_id then return end
  -- chansend appends as-is; ensure trailing newline
  if not payload:match("\n$") then payload = payload .. "\n" end
  local cfg = get_config()
  if cfg.bracketed_paste then
    local bp_start = "\x1b[200~"
    local bp_end = "\x1b[201~"
    vim.api.nvim_chan_send(holder.job_id, bp_start .. payload .. bp_end)
    
    -- Clear any selection in the terminal buffer after sending
    -- Neovim's terminal buffer may visually select text after bracketed paste
    if holder.term_bufnr and vim.api.nvim_buf_is_valid(holder.term_bufnr) then
      -- Use defer_fn with a small delay to ensure bracketed paste completes first
      vim.defer_fn(function()
        -- Use nvim_win_call to execute in the terminal window's context
        if holder.win_id and vim.api.nvim_win_is_valid(holder.win_id) then
          vim.api.nvim_win_call(holder.win_id, function()
            -- First, exit visual mode if we're in it
            local mode = vim.fn.mode()
            if mode == 'v' or mode == 'V' or mode == '\22' then
              vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
            end
            
            -- Get current cursor position
            local cursor_pos = vim.api.nvim_win_get_cursor(0)
            local line, col = cursor_pos[1], cursor_pos[2]
            
            -- Clear visual selection marks by setting both to cursor position
            -- Set both marks to the exact same position to clear any selection range
            vim.fn.setpos("'<", {holder.term_bufnr, line, col, 0})
            vim.fn.setpos("'>", {holder.term_bufnr, line, col, 0})
            
            -- Also try clearing by setting marks to invalid/zero positions as fallback
            -- This ensures the selection is definitely cleared
            if vim.fn.getpos("'<")[2] ~= line or vim.fn.getpos("'>")[2] ~= line then
              -- If marks are still different, force them to line 1, col 1
              vim.fn.setpos("'<", {holder.term_bufnr, 1, 1, 0})
              vim.fn.setpos("'>", {holder.term_bufnr, 1, 1, 0})
            end
            
            -- Force a redraw to clear any lingering visual selection highlight
            vim.cmd("redraw")
          end)
        end
      end, 50)  -- 50ms delay to ensure paste completes
    end
  else
    vim.api.nvim_chan_send(holder.job_id, payload)
  end
end

function M.open()
  ensure_session()
end

function M.close()
  local holder = get_active_holder()
  -- Use stop_holder which does complete cleanup
  stop_holder(holder)
end

function M.shutdown()
  -- Public method to stop all managed jobs
  -- This is called on VimLeavePre to ensure cleanup
  stop_holder(state.global)
  for tab_id, holder in pairs(state.per_tab) do
    stop_holder(holder)
  end
  -- Clear all state
  state.per_tab = {}
  state.global = { job_id = nil, term_bufnr = nil, win_id = nil }
end

function M.send_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  -- Convert 1-based inclusive to 0-based exclusive for nvim_buf_get_lines
  -- start_line and end_line are 1-based, inclusive
  -- nvim_buf_get_lines expects 0-based indices with exclusive end
  local start_1based = start_line or vim.fn.line(".")
  local end_1based = end_line or start_1based  -- Default to single line if end_line not provided
  
  -- Convert to 0-based: line 5 (1-based) = index 4 (0-based)
  local l1 = math.max(0, start_1based - 1)
  -- nvim_buf_get_lines uses exclusive end (end index is NOT included)
  -- To include line 10 (1-based, index 9), we need end=10 (exclusive)
  -- Example: lines 5-10 (1-based) = indices 4-9 (0-based)
  -- nvim_buf_get_lines(bufnr, 4, 10, false) returns indices 4-9 = lines 5-10 ✓
  local l2 = end_1based  -- Use directly as 0-based exclusive end
  
  local lines = vim.api.nvim_buf_get_lines(bufnr, l1, l2, false)
  if #lines == 0 then return end
  
  -- Check if buffer is modified and has a file path
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local is_modified = vim.bo[bufnr].modified
  
  if not is_modified and filepath and filepath ~= "" then
    -- Use @ file reference for unmodified files
    -- l1 and l2 are 0-based indices: l1 is inclusive start, l2 is exclusive end
    -- Convert to 1-based for file reference
    local start_1based_ref = l1 + 1  -- Convert 0-based to 1-based
    local end_1based_ref = l2        -- l2 = end_1based (already 1-based line number)
    local ref = build_file_reference(filepath, start_1based_ref, end_1based_ref)
    send_text(ref)
  else
    -- Fall back to copying content for modified files or buffers without paths
    local ft = vim.bo[bufnr].filetype
    local payload = build_payload(lines, ft)
    send_text(payload)
  end
end

function M.send_visual()
  -- visual selection using '< and '> marks
  -- Simply get the line numbers and delegate to send_range
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  
  -- Validate we have a valid selection
  if start_line < 1 or end_line < 1 or start_line > end_line then
    return
  end
  
  -- Use send_range which already handles ranges correctly
  -- This ensures consistent behavior between visual selections and explicit ranges
  M.send_range(start_line, end_line)
end

function M.send_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  if #lines == 0 then return end
  
  -- Check if buffer is modified and has a file path
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  local is_modified = vim.bo[bufnr].modified
  
  if not is_modified and filepath and filepath ~= "" then
    -- Use @ file reference for unmodified files
    local ref = build_file_reference(filepath)
    send_text(ref)
  else
    -- Fall back to copying content for modified files or buffers without paths
    local ft = vim.bo[bufnr].filetype
    local payload = build_payload(lines, ft)
    send_text(payload)
  end
end

function M.setup(user_config)
  state.config = vim.tbl_deep_extend("force", {}, default_config, user_config or {})
  local cfg = state.config
  -- Autocmds
  local aug = vim.api.nvim_create_augroup('CursorAgent', { clear = true })
  if cfg.kill_on_exit then
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = aug,
      callback = function()
        -- Use shutdown method which does complete cleanup
        M.shutdown()
      end,
    })
    
    -- Also handle BufUnload for terminal buffers to clean up when buffers are closed
    vim.api.nvim_create_autocmd('BufUnload', {
      group = aug,
      callback = function(opts)
        local bufnr = opts.buf
        -- Check if this is one of our terminal buffers
        if state.global.term_bufnr == bufnr then
          stop_holder(state.global)
        end
        for tab_id, holder in pairs(state.per_tab) do
          if holder.term_bufnr == bufnr then
            stop_holder(holder)
            state.per_tab[tab_id] = nil
          end
        end
      end,
    })
  end
end

return M


