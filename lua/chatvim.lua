-- Global state for managing active chat sessions
local active_sessions = {}
local session_counter = 0

-- Status bar integration
local status_component = {
	active_count = 0,
	update_callbacks = {},
}

-- Configuration (user configurable via setup). Defaults: no cursor movement.
local config = {
	auto_scroll = false, -- when true, auto-scrolls a visible window of the chat buffer
	show_spinner_window = false, -- when true, show a floating spinner window
	-- Buffer-local keymaps inside Chatvim chat buffers
	local_keymaps = {
		enabled = true, -- enabled by default
		map_enter = true, -- map <CR> in normal mode to :ChatvimComplete
		map_ctrl_enter = true, -- map <C-CR> in normal/visual (if supported by GUI/terminal)
	},
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
	if not config.auto_scroll then
		return
	end
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
		session_id = session_id,
	}
end

local function update_spinner(spinner)
	if not spinner.active or not spinner.buf or not spinner.win then
		return
	end
	spinner.index = spinner.index % #spinner.frames + 1
	vim.api.nvim_buf_set_lines(
		spinner.buf,
		0,
		-1,
		false,
		{ "🤖 Gemini thinking... " .. spinner.frames[spinner.index] }
	)
end

local function open_spinner_window(spinner)
	if not config.show_spinner_window then
		return
	end
	local ok, win = pcall(vim.api.nvim_get_current_win)
	if not ok or not win then
		return
	end
	local ok_conf, win_config = pcall(vim.api.nvim_win_get_config, win)
	if not ok_conf then
		return
	end
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
	if not spinner then
		return
	end
	if spinner.win then
		pcall(vim.api.nvim_win_close, spinner.win, true)
		spinner.win = nil
	end
	if spinner.buf then
		pcall(vim.api.nvim_buf_delete, spinner.buf, { force = true })
		spinner.buf = nil
	end
end

-- Normalize marker spacing around USER/ASSISTANT/SYSTEM delimiters
local function normalize_marker_spacing(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local n = #lines
	local out = {}

	local function is_marker(line)
		return line == "# === USER ===" or line == "# === ASSISTANT ===" or line == "# === SYSTEM ==="
	end

	local i = 1
	-- drop leading blank lines
	while i <= n and lines[i] == "" do
		i = i + 1
	end

	while i <= n do
		local l = lines[i]
		if is_marker(l) then
			-- ensure exactly one blank line before marker unless it's the very first line in file
			if #out > 0 and out[#out] ~= "" then
				table.insert(out, "")
			end
			table.insert(out, l)
			-- ensure exactly one blank line after marker
			table.insert(out, "")
			-- skip consecutive blanks in source right after marker
			local j = i + 1
			while j <= n and lines[j] == "" do
				j = j + 1
			end
			i = j
		else
			table.insert(out, l)
			i = i + 1
		end
	end

	-- write back only if changed
	local changed = false
	if #out ~= #lines then
		changed = true
	else
		for k = 1, #out do
			if out[k] ~= lines[k] then
				changed = true
				break
			end
		end
	end
	if changed then
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, out)
	end
end

-- Google Gemini API integration
local function make_gemini_request(content, session)
	local api_key = vim.env.GOOGLE_API_KEY or vim.env.GEMINI_API_KEY
	if not api_key then
		vim.api.nvim_echo(
			{ { "Error: GOOGLE_API_KEY or GEMINI_API_KEY environment variable not set", "ErrorMsg" } },
			false,
			{}
		)
		return
	end

	local model = vim.env.GEMINI_MODEL or "gemini-2.5-flash"
	local url = "https://generativelanguage.googleapis.com/v1beta/models/"
		.. model
		.. ":streamGenerateContent?alt=sse&key="
		.. api_key

	local payload = {
		contents = { {
			role = "user",
			parts = { { text = content } },
		} },
	}

	local json_payload = vim.fn.json_encode(payload)

	local curl_cmd = {
		"curl",
		"-sS",
		"-N",
		"-f",
		"-H",
		"Content-Type: application/json",
		"-H",
		"Accept: text/event-stream",
		"-d",
		json_payload,
		url,
	}

	local function handle_response_obj(response)
		if not response then
			return
		end
		if response.error then
			local msg = response.error.message or vim.fn.json_encode(response.error)
			vim.api.nvim_echo({ { "Gemini API Error: " .. msg, "ErrorMsg" } }, false, {})
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
								if ok then
									handle_response_obj(response)
								end
							end
						elseif trimmed:sub(1, 1) == "{" or trimmed:sub(1, 1) == "[" then
							local ok, response = pcall(vim.fn.json_decode, trimmed)
							if ok then
								handle_response_obj(response)
							end
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
						vim.api.nvim_echo({ { "Gemini API Error: " .. line, "ErrorMsg" } }, false, {})
					end
				end
			end)
		end,
		on_exit = function(_, code, _)
			vim.schedule(function()
				session:finalize()
				if code ~= 0 then
					vim.api.nvim_echo({ { "Gemini API request failed with code " .. code, "ErrorMsg" } }, false, {})
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
				vim.api.nvim_buf_set_lines(self.bufnr, -1, -1, false, { "", "# === USER ===", "" })
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
		vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# === USER ===" })
	end

	-- 2) Always append a new ASSISTANT marker at the end to start a fresh response block
	vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "", "# === ASSISTANT ===", "" })

	-- Normalize spacing around markers for clean structure (single blank line between sections)
	normalize_marker_spacing(bufnr)

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

-- JSON pretty-printer (pure Lua). Uses jq if available, otherwise formats here.
local function json_escape(str)
	return (
		str:gsub("\\", "\\\\")
			:gsub('"', '\\"')
			:gsub("\b", "\\b")
			:gsub("\f", "\\f")
			:gsub("\n", "\\n")
			:gsub("\r", "\\r")
			:gsub("\t", "\\t")
	)
end

local function is_array(tbl)
	if type(tbl) ~= "table" then
		return false
	end
	local n = 0
	local max = 0
	for k, _ in pairs(tbl) do
		if type(k) ~= "number" then
			return false
		end
		if k > max then
			max = k
		end
		n = n + 1
	end
	return n > 0 and max == n
end

local function encode_pretty_json(val, depth)
	depth = depth or 0
	local indent = string.rep("  ", depth)
	local next_indent = string.rep("  ", depth + 1)
	local t = type(val)
	if val == vim.NIL or t == "nil" then
		return '""'
	end
	if t == "number" or t == "boolean" then
		return tostring(val)
	end
	if t == "string" then
		return '"' .. json_escape(val) .. '"'
	end
	if t == "table" then
		if is_array(val) then
			if #val == 0 then
				return "[]"
			end
			local items = {}
			for i = 1, #val do
				table.insert(items, next_indent .. encode_pretty_json(val[i], depth + 1))
			end
			return "[\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "]"
		else
			local keys = {}
			for k, _ in pairs(val) do
				table.insert(keys, k)
			end
			table.sort(keys, function(a, b)
				return tostring(a) < tostring(b)
			end)
			if #keys == 0 then
				return "{}"
			end
			local items = {}
			for _, k in ipairs(keys) do
				local key_str = '"' .. json_escape(tostring(k)) .. '"'
				local v_str = encode_pretty_json(val[k], depth + 1)
				table.insert(items, next_indent .. key_str .. ": " .. v_str)
			end
			return "{\n" .. table.concat(items, ",\n") .. "\n" .. indent .. "}"
		end
	end
	return '""'
end

-- Open a new JSON buffer showing the request body to be sent
function M.debug_request()
	local bufnr = vim.api.nvim_get_current_buf()
	local body = build_gemini_request_from_buffer(bufnr)
	local raw = vim.fn.json_encode(body)

	local pretty = nil
	if vim.fn.executable("jq") == 1 then
		local ok, out = pcall(vim.fn.systemlist, "jq .", raw)
		if ok and type(out) == "table" and #out > 0 and vim.v.shell_error == 0 then
			pretty = out
		end
	end
	if not pretty then
		pretty = {}
		local s = encode_pretty_json(body)
		for line in s:gmatch("[^\n]+") do
			table.insert(pretty, line)
		end
	end

	-- Create a scratch JSON buffer in a new split (modifiable)
	vim.cmd("new")
	local out_buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_option(out_buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(out_buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(out_buf, "swapfile", false)
	vim.api.nvim_buf_set_option(out_buf, "modifiable", true)
	vim.api.nvim_buf_set_option(out_buf, "filetype", "json")
	vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, pretty)
	-- leave modifiable so user can tweak

	vim.api.nvim_echo({ { "Opened Gemini request body (JSON, pretty)", "Normal" } }, false, {})
end

-- Function to open a new markdown buffer in a left-side split

-- Apply buffer-local keymaps for Chatvim buffers
local function apply_buffer_local_keymaps(bufnr)
	if not config.local_keymaps.enabled then
		return
	end

	local opts = { noremap = true, silent = true, buffer = bufnr }

	-- In Normal mode, <CR> submits the prompt.
	if config.local_keymaps.map_enter then
		vim.keymap.set("n", "<CR>", ":ChatvimComplete<CR>", opts)
	end

	-- In Normal and Insert mode, <C-CR> submits the prompt.
	-- This is a common pattern for chat interfaces.
	if config.local_keymaps.map_ctrl_enter then
		-- Normal mode: submit
		vim.keymap.set("n", "<C-CR>", ":ChatvimComplete<CR>", opts)
		-- Insert mode: submit without adding a newline first
		vim.keymap.set("i", "<C-CR>", "<Esc>:ChatvimComplete<CR>", opts)
	end
end

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

	vim.bo.buftype = "nofile" -- No file backing, won't complain about unsaved changes

	-- Apply buffer-local keymaps
	apply_buffer_local_keymaps(vim.api.nvim_get_current_buf())
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

	-- Apply buffer-local keymaps
	apply_buffer_local_keymaps(vim.api.nvim_get_current_buf())

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

-- Optional Chatvim keybindings (configurable via setup)
local applied_keymaps = {}
local function clear_keymaps()
	for _, lhs in ipairs(applied_keymaps) do
		if vim.keymap and vim.keymap.del then
			pcall(vim.keymap.del, "n", lhs)
		else
			pcall(vim.api.nvim_del_keymap, "n", lhs)
		end
	end
	applied_keymaps = {}
end

local function map(lhs, rhs, desc)
	local opts = { noremap = true, silent = true, desc = desc }
	if vim.keymap and vim.keymap.set then
		vim.keymap.set("n", lhs, rhs, opts)
	else
		vim.api.nvim_set_keymap("n", lhs, rhs, opts)
	end
	table.insert(applied_keymaps, lhs)
end

local function apply_keymaps()
	clear_keymaps()
	if not (config.keymaps and config.keymaps.enabled) then
		return
	end
	local km = config.keymaps
	local p = km.prefix or "<Leader>cv"
	-- Commands
	map(p .. (km.complete or "c"), ":ChatvimComplete<CR>", "Chatvim: Complete")
	map(p .. (km.stop or "s"), ":ChatvimStop<CR>", "Chatvim: Stop current completion")
	map(p .. (km.stop_all or "S"), ":ChatvimStopAll<CR>", "Chatvim: Stop all completions")
	-- New chat
	local new = km.new or {}
	map(p .. (new.current or "nn"), ":ChatvimNew<CR>", "Chatvim: New chat (current window)")
	map(p .. (new.left or "nl"), ":ChatvimNewLeft<CR>", "Chatvim: New chat (left split)")
	map(p .. (new.right or "nr"), ":ChatvimNewRight<CR>", "Chatvim: New chat (right split)")
	map(p .. (new.top or "nt"), ":ChatvimNewTop<CR>", "Chatvim: New chat (top split)")
	map(p .. (new.bottom or "nb"), ":ChatvimNewBottom<CR>", "Chatvim: New chat (bottom split)")
	-- Help
	local help = km.help or {}
	map(p .. (help.current or "hh"), ":ChatvimHelp<CR>", "Chatvim: Help (current window)")
	map(p .. (help.left or "hl"), ":ChatvimHelpLeft<CR>", "Chatvim: Help (left split)")
	map(p .. (help.right or "hr"), ":ChatvimHelpRight<CR>", "Chatvim: Help (right split)")
	map(p .. (help.top or "ht"), ":ChatvimHelpTop<CR>", "Chatvim: Help (top split)")
	map(p .. (help.bottom or "hb"), ":ChatvimHelpBottom<CR>", "Chatvim: Help (bottom split)")
end

-- Export functions for external use (like lualine)
M.get_status = get_chatvim_status
M.register_status_callback = register_status_callback
M.stop_all_completions = M.stop_all_completions
M.apply_keymaps = apply_keymaps

return M
