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
  if not holder or not holder.job_id then return end
  if is_job_alive(holder.job_id) then
    -- try graceful interrupt, then stop
    pcall(vim.api.nvim_chan_send, holder.job_id, "\003")
    pcall(vim.fn.jobstop, holder.job_id)
  end
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

  local job_id = vim.fn.termopen(cmd, { cwd = vim.loop.cwd() })
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
  else
    vim.api.nvim_chan_send(holder.job_id, payload)
  end
end

function M.open()
  ensure_session()
end

function M.close()
  local holder = get_active_holder()
  if holder and holder.job_id and is_job_alive(holder.job_id) then
    -- Send Ctrl-C to attempt graceful exit; then close window
    pcall(vim.api.nvim_chan_send, holder.job_id, "\003")
    pcall(vim.fn.jobstop, holder.job_id)
  end
  if holder and holder.win_id and vim.api.nvim_win_is_valid(holder.win_id) then
    pcall(vim.api.nvim_win_close, holder.win_id, true)
  end
end

function M.shutdown()
  -- Public method to stop all managed jobs
  stop_holder(state.global)
  for _, holder in pairs(state.per_tab) do
    stop_holder(holder)
  end
end

function M.send_range(start_line, end_line)
  local bufnr = vim.api.nvim_get_current_buf()
  local l1 = math.max(0, (start_line or vim.fn.line(".") ) - 1)
  local l2 = math.max(l1, (end_line or start_line or vim.fn.line(".") ))
  local lines = vim.api.nvim_buf_get_lines(bufnr, l1, l2, true)
  if #lines == 0 then return end
  local ft = vim.bo[bufnr].filetype
  local payload = build_payload(lines, ft)
  send_text(payload)
end

function M.send_visual()
  -- visual selection using '< and '>
  local bufnr = vim.api.nvim_get_current_buf()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local l1 = math.max(0, start_pos[2] - 1)
  local l2 = math.max(l1, end_pos[2])
  local lines = vim.api.nvim_buf_get_lines(bufnr, l1, l2, true)
  if #lines == 0 then return end
  local ft = vim.bo[bufnr].filetype
  local payload = build_payload(lines, ft)
  send_text(payload)
end

function M.send_buffer()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
  if #lines == 0 then return end
  local ft = vim.bo[bufnr].filetype
  local payload = build_payload(lines, ft)
  send_text(payload)
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
        -- Stop global holder
        stop_holder(state.global)
        -- Stop per-tab holders
        for _, holder in pairs(state.per_tab) do
          stop_holder(holder)
        end
      end,
    })
  end
end

return M


