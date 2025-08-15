-- Global state for managing active chat sessions
local active_sessions = {}
local session_counter = 0

-- Status bar integration
local status_component = {
  active_count = 0,
  update_callbacks = {}
}

-- Configuration (user configurable via setup). Defaults: no cursor movement.
local config = {
  auto_scroll = false, -- when true, auto-scrolls a visible window of the chat buffer
  show_spinner_window = false, -- when true, show a floating spinner window
}

-- Session management
local function create_session_id()
  session_counter = session_counter + 1
  return session_counter
end

local function update_status_bar()
  status_component.active_count = vim.tbl_count(active_sessions)
  for _, callback in ipairs(status_component.update_callbacks) do
    callback(status_component.active_count)
  end
end

-- Register status bar update callback (for lualine integration)
local function register_status_callback(callback)
  table.insert(status_component.update_callbacks, callback)
end

-- Get status for lualine
local function get_chatvim_status()
  local count = status_component.active_count
  if count == 0 then
    return ""
  elseif count == 1 then
    return "🤖 1 chat"
  else
    return "🤖 " .. count .. " chats"
  end
end

-- Safely scroll a window showing the given buffer to its bottom
local function safe_scroll_to_bottom(bufnr)
  if not config.auto_scroll then return end
  local wins = vim.fn.win_findbuf(bufnr)
  if wins and #wins > 0 then
    local last_line = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, wins[1], { math.max(1, last_line), 0 })
  end
end

-- Spinner for individual sessions
local function create_spinner(session_id)
  return {
    frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
    index = 1,
    active = false,
    buf = nil,
    win = nil,
    timer = nil,
    session_id = session_id
  }
end

local function update_spinner(spinner)
  if not spinner.active or not spinner.buf or not spinner.win then
    return
  end
  spinner.index = spinner.index % #spinner.frames + 1
  vim.api.nvim_buf_set_lines(spinner.buf, 0, -1, false, { "🤖 Gemini thinking... " .. spinner.frames[spinner.index] })
end

local function open_spinner_window(spinner)
  if not config.show_spinner_window then return end
  local ok, win = pcall(vim.api.nvim_get_current_win)
  if not ok or not win then return end
  local ok_conf, win_config = pcall(vim.api.nvim_win_get_config, win)
  if not ok_conf then return end
  local width = win_config.width or vim.api.nvim_win_get_width(win)
  local height = win_config.height or vim.api.nvim_win_get_height(win)

  local spinner_width = 25
  local spinner_height = 1
  local col = math.floor((width - spinner_width) / 2)
  local row = math.floor((height - spinner_height) / 2)

  spinner.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(spinner.buf, 0, -1, false, { "🤖 Gemini thinking... " .. spinner.frames[1] })
  spinner.win = vim.api.nvim_open_win(spinner.buf, false, {
    relative = "win",
    win = win,
    width = spinner_width,
    height = spinner_height,
    col = col,
    row = row,
    style = "minimal",
    border = "single",
  })
end

local function close_spinner_window(spinner)
  if not spinner then return end
  if spinner.win then
    pcall(vim.api.nvim_win_close, spinner.win, true)
    spinner.win = nil
  end
  if spinner.buf then
    pcall(vim.api.nvim_buf_delete, spinner.buf, { force = true })
    spinner.buf = nil
  end
end

-- Google Gemini API integration
local function make_gemini_request(content, session)
  local api_key = vim.env.GOOGLE_API_KEY or vim.env.GEMINI_API_KEY
  if not api_key then
    vim.api.nvim_echo({{"Error: GOOGLE_API_KEY or GEMINI_API_KEY environment variable not set", "ErrorMsg"}}, false, {})
    return
  end

  local model = vim.env.GEMINI_MODEL or "gemini-2.5-flash"
  local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. model .. ":streamGenerateContent?alt=sse&key=" .. api_key
  
  local payload = {
    contents = {{
      role = "user",
      parts = {{ text = content }},
    }}
  }

  local json_payload = vim.fn.json_encode(payload)
  
  local curl_cmd = {
    "curl", "-sS", "-N", "-f",
    "-H", "Content-Type: application/json",
    "-H", "Accept: text/event-stream",
    "-d", json_payload,
    url
  }

  local function handle_response_obj(response)
    if not response then return end
    if response.error then
      local msg = response.error.message or vim.fn.json_encode(response.error)
      vim.api.nvim_echo({{"Gemini API Error: " .. msg, "ErrorMsg"}}, false, {})
      return
    end
    local candidates = response.candidates or {}
    if candidates[1] and candidates[1].content and candidates[1].content.parts then
      for _, part in ipairs(candidates[1].content.parts) do
        if type(part) == "table" and part.text then
          session:append_chunk(part.text)
        end
      end
    end
  end

  local job_id = vim.fn.jobstart(curl_cmd, {
    on_stdout = function(_, data, _)
      vim.schedule(function()
        for _, line in ipairs(data) do
          if line and line ~= "" then
            local trimmed = line:gsub("\r$", "")
            if trimmed:match("^data:%s*%[DONE%]%s*$") then
              -- end of stream
            elseif trimmed:match("^data:") then
              local json_str = trimmed:gsub("^data:%s*", "")
              if json_str ~= "" then
                local ok, response = pcall(vim.fn.json_decode, json_str)
                if ok then handle_response_obj(response) end
              end
            elseif trimmed:sub(1,1) == "{" or trimmed:sub(1,1) == "[" then
              local ok, response = pcall(vim.fn.json_decode, trimmed)
              if ok then handle_response_obj(response) end
            else
              -- ignore other lines
            end
          end
        end
      end)
    end,
    on_stderr = function(_, data, _)
      vim.schedule(function()
        for _, line in ipairs(data) do
          if line ~= "" then
            vim.api.nvim_echo({{"Gemini API Error: " .. line, "ErrorMsg"}}, false, {})
          end
        end
      end)
    end,
    on_exit = function(_, code, _)
      vim.schedule(function()
        session:finalize()
        if code ~= 0 then
          vim.api.nvim_echo({{"Gemini API request failed with code " .. code, "ErrorMsg"}}, false, {})
        end
      end)
    end,
    stdout_buffered = false,
  })

  return job_id
end

local M = {}

-- Public setup to configure behavior
function M.setup(user_config)
  config = vim.tbl_deep_extend("force", config, user_config or {})
end

function M.complete_text()
  local CompletionSession = {}
  CompletionSession.__index = CompletionSession

  function CompletionSession:new(bufnr, orig_last_line, orig_line_count)
    local session_id = create_session_id()
    local session = setmetatable({
      id = session_id,
      bufnr = bufnr,
      orig_last_line = orig_last_line,
      orig_line_count = orig_line_count,
      first_chunk = true,
      partial = "",
      update_timer = nil,
      spinner = create_spinner(session_id),
      job_id = nil,
    }, self)
    
    -- Register this session
    active_sessions[session_id] = session
    update_status_bar()
    
    return session
  end

  function CompletionSession:append_chunk(chunk)
    self.partial = self.partial .. chunk

    -- Only schedule a buffer update if there isn't already a timer running
    if not self.update_timer then
      self.update_timer = vim.loop.new_timer()
      self.update_timer:start(
        100,
        0,
        vim.schedule_wrap(function()
          -- Process the accumulated content
          local lines = vim.split(self.partial, "\n", { plain = true })
          local last_line_num = vim.api.nvim_buf_line_count(self.bufnr) - 1

          -- Always write starting at the current end of buffer
          vim.api.nvim_buf_set_lines(self.bufnr, last_line_num, last_line_num + 1, false, { lines[1] })

          -- Append any additional complete lines
          if #lines > 2 then
            vim.api.nvim_buf_set_lines(
              self.bufnr,
              last_line_num + 1,
              last_line_num + 1,
              false,
              { unpack(lines, 2, #lines - 1) }
            )
          end

          -- Keep the last (potentially incomplete) line in the buffer
          self.partial = lines[#lines]
          vim.api.nvim_buf_set_lines(
            self.bufnr,
            last_line_num + (#lines - 1),
            last_line_num + (#lines - 1) + 1,
            false,
            { self.partial }
          )

          -- Try to scroll any window that shows this buffer to bottom (if visible)
          safe_scroll_to_bottom(self.bufnr)

          -- Clean up the timer
          if self.update_timer then
            self.update_timer:stop()
            self.update_timer:close()
            self.update_timer = nil
          end
        end)
      )
    end

    return self.partial
  end

  function CompletionSession:finalize()
    -- Stop any pending timer to ensure updates are applied immediately
    if self.update_timer then
      self.update_timer:stop()
      self.update_timer:close()
      self.update_timer = nil
    end
    
    -- Stop spinner
    self.spinner.active = false
    if self.spinner.timer then
      self.spinner.timer:stop()
      self.spinner.timer = nil
    end
    close_spinner_window(self.spinner)
    
    -- Write any remaining buffered content when the process ends
    if self.partial ~= "" then
      local lines = vim.split(self.partial, "\n", { plain = true })
      local last_line_num = vim.api.nvim_buf_line_count(self.bufnr) - 1

      -- Always write starting at the current end of buffer
      vim.api.nvim_buf_set_lines(self.bufnr, last_line_num, last_line_num + 1, false, { lines[1] })

      -- Append any additional complete lines
      if #lines > 2 then
        vim.api.nvim_buf_set_lines(
          self.bufnr,
          last_line_num + 1,
          last_line_num + 1,
          false,
          { unpack(lines, 2, #lines - 1) }
        )
      end

      -- Keep the last (potentially incomplete) line in the buffer
      self.partial = lines[#lines]
      vim.api.nvim_buf_set_lines(
        self.bufnr,
        last_line_num + (#lines - 1),
        last_line_num + (#lines - 1) + 1,
        false,
        { self.partial }
      )

      -- Try to scroll any window that shows this buffer to bottom (if visible)
      safe_scroll_to_bottom(self.bufnr)

      -- Reset partial after finalizing
      self.partial = ""
    end
    
    -- Ensure there is a trailing USER marker so the next input is not considered assistant
    do
      local all_lines = vim.api.nvim_buf_get_lines(self.bufnr, 0, -1, false)
      local last_nonempty = nil
      for i = #all_lines, 1, -1 do
        if all_lines[i] ~= "" then
          last_nonempty = all_lines[i]
          break
        end
      end
      if last_nonempty ~= "# === USER ===" then
        vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, {"", "# === USER ===", ""})
      end
    end

    -- Unregister session
    active_sessions[self.id] = nil
    update_status_bar()
    
    vim.api.nvim_echo({ { "🤖 Gemini response complete", "Normal" } }, false, {})
  end

  local bufnr = vim.api.nvim_get_current_buf()
  if not vim.bo[bufnr].modifiable then
    vim.api.nvim_echo({ { "No file open to complete.", "WarningMsg" } }, false, {})
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local orig_last_line = lines[#lines] or ""
  local orig_line_count = #lines
  local session = CompletionSession:new(bufnr, orig_last_line, orig_line_count)

  -- Optional spinner window/animation (disabled by default)
  session.spinner.active = config.show_spinner_window
  if config.show_spinner_window then
    open_spinner_window(session.spinner)
    session.spinner.timer = vim.loop.new_timer()
    session.spinner.timer:start(
      0,
      80,
      vim.schedule_wrap(function()
        if session.spinner.active then
          update_spinner(session.spinner)
        else
          if session.spinner.timer then
            session.spinner.timer:stop()
            session.spinner.timer = nil
          end
        end
      end)
    )
  end

  -- Ensure required delimiters exist in the buffer (modify buffer first)
  -- 1) Ensure USER marker at start if missing
  local has_user = false
  for _, l in ipairs(lines) do
    if l:find("# === USER ===", 1, true) then
      has_user = true
      break
    end
  end
  if not has_user then
    -- Insert USER marker at the very top
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, {"# === USER ===", ""})
  end

  -- 2) Ensure ASSISTANT marker exists somewhere; if missing, append near end
  lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local joined = table.concat(lines, "\n")
  if not joined:find("# === ASSISTANT ===", 1, true) then
    vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, {"", "# === ASSISTANT ===", ""})
  end

  -- Recompute full content from buffer after any delimiter insertions
  lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local content = table.concat(lines, "\n")

  -- Make Gemini API request
  local job_id = make_gemini_request(content, session)
  
  if not job_id or job_id <= 0 then
    vim.api.nvim_echo({ { "Failed to start Gemini request", "ErrorMsg" } }, false, {})
    session:finalize()
    return
  end

  session.job_id = job_id
end

function M.stop_completion()
  local bufnr = vim.api.nvim_get_current_buf()
  local session_to_stop = nil
  
  -- Find session for current buffer
  for _, session in pairs(active_sessions) do
    if session.bufnr == bufnr then
      session_to_stop = session
      break
    end
  end
  
  if not session_to_stop then
    vim.api.nvim_echo({ { "No active completion in this buffer", "Normal" } }, false, {})
    return
  end

  -- Stop the running job
  if session_to_stop.job_id then
    vim.fn.jobstop(session_to_stop.job_id)
  end
  
  vim.api.nvim_echo({ { "🤖 Gemini completion stopped", "Normal" } }, false, {})

  -- Finalize the session
  session_to_stop:finalize()
end

function M.stop_all_completions()
  if vim.tbl_isempty(active_sessions) then
    vim.api.nvim_echo({ { "No active completions", "Normal" } }, false, {})
    return
  end
  
  local count = 0
  for _, session in pairs(active_sessions) do
    if session.job_id then
      vim.fn.jobstop(session.job_id)
    end
    session:finalize()
    count = count + 1
  end
  
  vim.api.nvim_echo({ { "🤖 Stopped " .. count .. " Gemini completions", "Normal" } }, false, {})
end

-- Build a Gemini request body from the current buffer by parsing delimiters
local function build_gemini_request_from_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local messages = {}
  local system_parts = {}

  local current_role = nil
  local current_text = {}

  local function flush()
    if current_role and #current_text > 0 then
      local text = table.concat(current_text, "\n")
      if current_role == "system" then
        table.insert(system_parts, text)
      else
        local role = (current_role == "assistant") and "model" or "user"
        table.insert(messages, { role = role, parts = { { text = text } } })
      end
    end
    current_role = nil
    current_text = {}
  end

  local function is_delim(line, what)
    return line == "# === " .. what .. " ==="
  end

  for _, l in ipairs(lines) do
    if is_delim(l, "USER") then
      flush()
      current_role = "user"
    elseif is_delim(l, "ASSISTANT") then
      flush()
      current_role = "assistant"
    elseif is_delim(l, "SYSTEM") then
      flush()
      current_role = "system"
    else
      table.insert(current_text, l)
    end
  end
  flush()

  -- If no delimiters found, treat entire buffer as one user message
  if #messages == 0 and #system_parts == 0 then
    local text = table.concat(lines, "\n")
    messages = { { role = "user", parts = { { text = text } } } }
  end

  local body = { contents = messages }
  if #system_parts > 0 then
    body.system_instruction = { parts = { { text = table.concat(system_parts, "\n\n") } } }
  end
  return body
end

-- Open a new JSON buffer showing the request body to be sent
function M.debug_request()
  local bufnr = vim.api.nvim_get_current_buf()
  local body = build_gemini_request_from_buffer(bufnr)
  local json = vim.fn.json_encode(body)

  -- Create a scratch JSON buffer in a new split
  vim.cmd("new")
  local out_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_option(out_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(out_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(out_buf, "swapfile", false)
  vim.api.nvim_buf_set_option(out_buf, "modifiable", true)
  vim.api.nvim_buf_set_option(out_buf, "filetype", "json")
  vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, { json })
  vim.api.nvim_buf_set_option(out_buf, "modifiable", false)

  vim.api.nvim_echo({ { "Opened Gemini request body (JSON)", "Normal" } }, false, {})
end

-- Function to open a new markdown buffer in a left-side split

local function open_chatvim_window(args)
  -- Generate a unique filename like "/path/to/cwd/chat-YYYY-MM-DD-HH-MM-SS.md"
  local filename = vim.fn.getcwd() .. "/chat-" .. os.date("%Y-%m-%d-%H-%M-%S") .. ".md"

  -- Determine window placement based on argument
  local placement = args.args or ""
  local split_cmd = ""

  if placement == "left" then
    split_cmd = "topleft vsplit"
  elseif placement == "right" then
    split_cmd = "botright vsplit"
  elseif placement == "top" then
    split_cmd = "topleft split"
  elseif placement == "bottom" or placement == "bot" then
    split_cmd = "botright split"
  end

  -- Open the split if specified
  if split_cmd ~= "" then
    vim.cmd(split_cmd)
  end

  -- Edit the new file in the target window (creates a new unsaved buffer with the filename)
  vim.cmd("edit " .. vim.fn.fnameescape(filename))

  -- Optional: Ensure filetype is markdown (usually auto-detected, but explicit for safety)
  vim.bo.filetype = "markdown"
end

-- Function to open a new markdown buffer prefilled with help text from Node.js
local function open_chatvim_help_window(args)
  -- Generate a unique filename like "/path/to/cwd/chat-YYYY-MM-DD-HH-MM-SS.md"
  local filename = vim.fn.getcwd() .. "/chat-" .. os.date("%Y-%m-%d-%H-%M-%S") .. ".md"

  -- Determine window placement based on argument
  local placement = args.args or ""
  local split_cmd = ""

  if placement == "left" then
    split_cmd = "topleft vsplit"
  elseif placement == "right" then
    split_cmd = "botright vsplit"
  elseif placement == "top" then
    split_cmd = "topleft split"
  elseif placement == "bottom" or placement == "bot" then
    split_cmd = "botright split"
  end

  -- Open the split if specified
  if split_cmd ~= "" then
    vim.cmd(split_cmd)
  end

  -- Edit the new file in the target window (creates a new unsaved buffer with the filename)
  vim.cmd("edit " .. vim.fn.fnameescape(filename))

  -- Optional: Ensure filetype is markdown (usually auto-detected, but explicit for safety)
  vim.bo.filetype = "markdown"

  -- Get the current buffer (newly created)
  local buf = vim.api.nvim_get_current_buf()

  -- Define path to the help.md file (in the same directory as this Lua file)
  local plugin_dir = debug.getinfo(1, "S").source:sub(2):match("(.*/)")
  local help_path = plugin_dir .. "help.md"

  -- Read the contents of help.md
  local output_lines = vim.fn.readfile(help_path)
  -- add two lines at the end of the output
  table.insert(output_lines, "")
  table.insert(output_lines, "")

  -- Insert the contents into the buffer
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, output_lines)

  -- Move cursor to the end of the content
  local last_line = #output_lines
  vim.api.nvim_win_set_cursor(0, { last_line, 0 })

  -- Center the cursor at the bottom (equivalent to 'zz')
  vim.cmd("normal! zz")
end

-- Define a new command called 'ChatvimNew' with an optional argument
vim.api.nvim_create_user_command("ChatvimNew", open_chatvim_window, {
  nargs = "?", -- Accepts 0 or 1 argument
  desc = "Open a new markdown buffer in this window",
})

vim.api.nvim_create_user_command("ChatvimNewLeft", function()
  open_chatvim_window({ args = "left" })
end, { desc = "Open a new markdown buffer in a left-side split" })

vim.api.nvim_create_user_command("ChatvimNewRight", function()
  open_chatvim_window({ args = "right" })
end, { desc = "Open a new markdown buffer in a right-side split" })

vim.api.nvim_create_user_command("ChatvimNewTop", function()
  open_chatvim_window({ args = "top" })
end, { desc = "Open a new markdown buffer in a top split" })

vim.api.nvim_create_user_command("ChatvimNewBottom", function()
  open_chatvim_window({ args = "bottom" })
end, { desc = "Open a new markdown buffer in a bottom split" })

vim.api.nvim_create_user_command("ChatvimComplete", function()
  require("chatvim").complete_text()
end, { desc = "Complete text using Google Gemini" })

vim.api.nvim_create_user_command("ChatvimStop", function()
  require("chatvim").stop_completion()
end, { desc = "Stop Gemini completion in current buffer" })

vim.api.nvim_create_user_command("ChatvimStopAll", function()
  require("chatvim").stop_all_completions()
end, { desc = "Stop all active Gemini completions" })

vim.api.nvim_create_user_command("ChatvimHelp", open_chatvim_help_window, {
  nargs = "?", -- Accepts 0 or 1 argument
  desc = "Open a new markdown buffer with help text in this window",
})

vim.api.nvim_create_user_command("ChatvimHelpLeft", function()
  open_chatvim_help_window({ args = "left" })
end, {
  desc = "Open a new markdown buffer with help text in a left-side split",
})

vim.api.nvim_create_user_command("ChatvimHelpRight", function()
  open_chatvim_help_window({ args = "right" })
end, {
  desc = "Open a new markdown buffer with help text in a right-side split",
})

vim.api.nvim_create_user_command("ChatvimHelpTop", function()
  open_chatvim_help_window({ args = "top" })
end, {
  desc = "Open a new markdown buffer with help text in a top split",
})

vim.api.nvim_create_user_command("ChatvimHelpBottom", function()
  open_chatvim_help_window({ args = "bottom" })
end, {
  desc = "Open a new markdown buffer with help text in a bottom split",
})

vim.api.nvim_create_user_command("ChatvimDebugRequest", function()
  require("chatvim").debug_request()
end, { desc = "Open a JSON buffer showing the exact Gemini request body" })

-- Chatvim (chatvim.nvim) keybindings
local opts = { noremap = true, silent = true }
vim.api.nvim_set_keymap("n", "<Leader>cvc", ":ChatvimComplete<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvs", ":ChatvimStop<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvS", ":ChatvimStopAll<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvnn", ":ChatvimNew<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvnl", ":ChatvimNewLeft<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvnr", ":ChatvimNewRight<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvnt", ":ChatvimNewTop<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvnb", ":ChatvimNewBottom<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvhh", ":ChatvimHelp<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvhl", ":ChatvimHelpLeft<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvhr", ":ChatvimHelpRight<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvht", ":ChatvimHelpTop<CR>", opts)
vim.api.nvim_set_keymap("n", "<Leader>cvhb", ":ChatvimHelpBottom<CR>", opts)

-- Export functions for external use (like lualine)
M.get_status = get_chatvim_status
M.register_status_callback = register_status_callback
M.stop_all_completions = M.stop_all_completions

return M
