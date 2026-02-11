local config = require("tabs.config")
local utils = require("tabs.utils")

local tabs = {}

--- Information about the buffers the user visits. This is always sorted by recency, i.e.,
--- the first element is the current buffer, the second is the lasy visited buffer, etc.
---
---@type { buffer: integer, icon: string | nil, icon_color: string | nil }[]
local visited_buffers = {}

local selected_index = 1
local view_start = 1

local function get_offset_width()
	local total = 0
	for _, offset in ipairs(config.options.offsets) do
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			local buffer = vim.api.nvim_win_get_buf(window)
			if vim.api.nvim_get_option_value("filetype", { buf = buffer }) == offset.filetype then
				total = total + vim.api.nvim_win_get_width(window)
			end
		end
	end
	return total
end

local function get_tab_width(buffer_info)
	local ok, name = pcall(vim.api.nvim_buf_get_name, buffer_info.buffer)
	if not ok then return 0 end
	local title = name:match("([^/]+)$") or ""
	local width = #title + 2
	if buffer_info.icon ~= nil then
		width = width + 2
	end
	return width
end

local function get_view_end()
	local available = vim.o.columns - get_offset_width()
	local total = 0
	local last = math.min(view_start + config.options.max_tabs - 1, #visited_buffers)
	for i = view_start, last do
		local w = get_tab_width(visited_buffers[i])
		if i > view_start then w = w + 1 end
		if total + w > available and i > view_start then
			return i - 1
		end
		total = total + w
	end
	return last
end

local function ensure_selected_visible()
	if selected_index < view_start then
		view_start = selected_index
	end
	while get_view_end() < selected_index and view_start < selected_index do
		view_start = view_start + 1
	end
end

--- Removes non-real buffers (e.g., telescope prompts, nofile scratch buffers)
--- from the visited_buffers list.
local function prune_buffers()
	visited_buffers = vim.tbl_filter(function(buffer_info)
		local buf = buffer_info.buffer
		return vim.api.nvim_buf_is_valid(buf)
			and vim.bo[buf].buflisted
			and vim.bo[buf].buftype == ""
	end, visited_buffers)
end

--- Formats the given text to be highlighted with the given highlight group,
--- as Vim expects it to be when rendering the tabline.
---
---@param text string The text to highlight
---@param group HighlightName The highlight group to highlight it with
---
---@return string text The highlighted text
function tabs.highlight(text, group)
	return "%#" .. group .. "#" .. text .. "%#TabsUnfocused#"
end

--- Creates the tabline. This is passed to `vim.opt.tabline` in the form:
---
--- ```lua
--- vim.opt.tabline = "%!v:lua.require('tabs').tabline()"
--- ```
---
--- When doing so, ensure that `vim.opt.showtabline = 2`.
---
---@return nil
function tabs.tabline()
	local result = ""

	-- Offsets
	for _, offset in ipairs(config.options.offsets) do
		for _, window in ipairs(vim.api.nvim_list_wins()) do
			local buffer = vim.api.nvim_win_get_buf(window)
			if vim.api.nvim_get_option_value("filetype", { buf = buffer }) == offset.filetype then
				result = result .. utils.center(offset.title(), vim.api.nvim_win_get_width(window))
			end
		end
	end

	-- Buffers
	local view_end = get_view_end()
	for index = view_start, view_end do
		local buffer_info = visited_buffers[index]

		local buffer_exists, buffer_name = pcall(function()
			return vim.api.nvim_buf_get_name(buffer_info.buffer)
		end)

		local highlight = "TabsUnfocused"
		if index == selected_index then
			highlight = "TabsSelected"
		end
		if index == 1 then
			highlight = "TabsFocused"
		end

		if buffer_exists then
			local tab_title = buffer_name:match("([^/]+)$") or ""

			-- Separator (before tab, between non-first tabs)
			if index ~= view_start then
				result = result .. tabs.highlight("│", "TabsSeparator")
			end

			-- Left padding
			result = result .. tabs.highlight(" ", highlight)

			-- Icon
			if buffer_info.icon ~= nil then
				result = result .. tabs.highlight(buffer_info.icon .. " ", buffer_info.icon_color)
			end

			-- Title
			result = result .. tabs.highlight(tab_title, highlight)

			-- Right padding
			result = result .. tabs.highlight(" ", highlight)
		end
	end

	result = result .. tabs.highlight("", "TabsFocused")

	return result
end

--- Selects the next (right) tab.
---
---@return nil
function tabs.next()
	selected_index = math.min(selected_index + 1, #visited_buffers)
	ensure_selected_visible()
	vim.cmd("redrawtabline")
end

--- Selects the previous (left) tab.
---
---@return nil
function tabs.previous()
	selected_index = math.max(selected_index - 1, 1)
	ensure_selected_visible()
	vim.cmd("redrawtabline")
end

--- Opens the selected tab.
---
---@return nil
function tabs.open()
	if #visited_buffers == 0 then
		return
	end
	vim.api.nvim_set_current_buf(visited_buffers[selected_index].buffer)
	selected_index = 1
	view_start = 1
	vim.cmd("redrawtabline")
	if config.options.autohide then
		vim.opt.showtabline = 0
	end
end

--- Returns the file paths of visited buffers in order, for session persistence.
---
---@return string[]
function tabs.get_visited_paths()
	local paths = {}
	for _, buffer_info in ipairs(visited_buffers) do
		local ok, name = pcall(vim.api.nvim_buf_get_name, buffer_info.buffer)
		if ok and name ~= "" then
			table.insert(paths, name)
		end
	end
	return paths
end

--- Reorders visited_buffers to match a previously saved path order.
--- Buffers not in the saved order are appended at the end.
---
---@param paths string[]
function tabs.restore_visited_order(paths)
	local path_to_rank = {}
	for i, path in ipairs(paths) do
		path_to_rank[path] = i
	end

	table.sort(visited_buffers, function(a, b)
		local ok_a, name_a = pcall(vim.api.nvim_buf_get_name, a.buffer)
		local ok_b, name_b = pcall(vim.api.nvim_buf_get_name, b.buffer)
		local rank_a = (ok_a and path_to_rank[name_a]) or math.huge
		local rank_b = (ok_b and path_to_rank[name_b]) or math.huge
		return rank_a < rank_b
	end)

	selected_index = 1
	view_start = 1
	vim.cmd("redrawtabline")
end

--- Sets up the plugin's highlights based on the user's configuration.
---
---@param highlights table<HighlightName, Highlight> The highlights from the user's configuration
---
---@return nil
local function setup_highlights(highlights)
	for name, opts in pairs(highlights) do
		vim.api.nvim_set_hl(0, name, opts)
	end
end

--- Called when the user enters a buffer. This gets information about the buffer
--- and adds it to the beginning of the `visited_buffers` list, removing old
--- information about the buffer if it exists.
---
---@param buffer integer The buffer number the user opened
---
---@return nil
local function visit_buffer(buffer)
	-- Ignored
	if vim.list_contains(config.options.ignored, vim.bo.ft) then
		return
	end

	-- Remove existing entry
	visited_buffers = vim.tbl_filter(function(buffer_info)
		return buffer_info.buffer ~= buffer
	end, visited_buffers)

	-- Devicon
	local has_devicons, devicons = pcall(function()
		return require("nvim-web-devicons")
	end)
	local icon = nil
	local icon_color = nil
	if has_devicons then
		local filetype = vim.api.nvim_get_option_value("filetype", { buf = buffer })
		icon = devicons.get_icon_by_filetype(filetype, {})

		local icon_name = devicons.get_icon_name_by_filetype(filetype) or ""
		local icon_group = "DevIcon" .. icon_name:sub(1, 1):upper() .. icon_name:sub(2)

		local source = vim.api.nvim_get_hl(0, { name = icon_group })
		vim.api.nvim_set_hl(0, "Tabs" .. icon_group, {
			fg = source.fg,
			ctermfg = source.ctermfg,
		})

		icon_color = "Tabs" .. icon_group
	end

	-- Add it
	table.insert(visited_buffers, 1, { buffer = buffer, icon = icon, icon_color = icon_color })

	-- Prune fake buffers from telescope, etc.
	prune_buffers()

	-- Reload
	vim.cmd("redrawtabline")
end

--- Sets up the tabline plugin with the specified options.
---
---@param opts TabUserConfig Configuration options from the plugin user.
---
---@return nil
tabs.setup = function(opts)
	config.setup(opts)
	setup_highlights(config.options.highlights)

	vim.api.nvim_create_user_command("TabsNext", tabs.next, {})
	vim.api.nvim_create_user_command("TabsPrevious", tabs.previous, {})
	vim.api.nvim_create_user_command("TabsOpen", tabs.open, {})

	vim.opt.showtabline = 2
	if config.options.autohide then
		vim.opt.showtabline = 0
	end

	vim.opt.tabline = "%!v:lua.require('tabs').tabline()"

	vim.api.nvim_create_autocmd("BufEnter", {
		callback = function(args)
			visit_buffer(args.buf)
		end,
	})

	vim.api.nvim_create_autocmd("BufDelete", {
		callback = function(args)
			visited_buffers = vim.tbl_filter(function(buffer_info)
				return buffer_info.buffer ~= args.buf
			end, visited_buffers)
			vim.cmd("redrawtabline")
		end,
	})

	-- Repopulate visited_buffers after session restore
	vim.api.nvim_create_autocmd("SessionLoadPost", {
		callback = function()
			visited_buffers = {}
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.api.nvim_buf_is_valid(buf)
					and vim.bo[buf].buflisted
					and vim.bo[buf].buftype == "" then
					visit_buffer(buf)
				end
			end
		end,
	})
end

return tabs
