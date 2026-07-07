local wezterm = require("wezterm")
local io = require("io")
local os = require("os")

local M = {}

local DEFAULTS = {
	separator = "  \u{e0b3}  ",
	show_time = true,
	always_show_time_separator = true,
	max_age_seconds = 300,
	auto_update = true,
	update_interval_seconds = 2,
	update_delay_seconds = 0.2,
	binary_path = os.getenv("WEZTERM_GIT_STATUS_BRIDGE_BIN") or "wezterm-git-status-bridge",
	status_bg = "#1f1f28",
	mode_styles = nil,
	show_git_for_pane = nil,
	on_reload = nil,
	time_format = "%a %b %e %H:%M",
	repo_prefix = "  ",
	ref_prefix = " ",
	worktree_text = "󰙅 ",
	time_prefix = " ",
	time_suffix = "  ",
	colors = {
		muted = "#565f89",
		repo = "#c0caf5",
		ref = "#7dcfff",
		detached = "#ff9e64",
		dirty = "#e6c384",
		worktree = "#9ece6a",
		time = "#bb9af7",
	},
}

local function merge_options(options)
	options = options or {}
	local colors = {}
	for key, value in pairs(DEFAULTS.colors) do
		colors[key] = value
	end
	for key, value in pairs(options.colors or {}) do
		colors[key] = value
	end
	return {
		separator = options.separator or DEFAULTS.separator,
		show_time = options.show_time ~= false,
		always_show_time_separator = options.always_show_time_separator == nil
				and DEFAULTS.always_show_time_separator
			or options.always_show_time_separator,
		cache_dir = options.cache_dir,
		max_age_seconds = options.max_age_seconds == nil and DEFAULTS.max_age_seconds or options.max_age_seconds,
		auto_update = options.auto_update == nil and DEFAULTS.auto_update or options.auto_update,
		update_interval_seconds = options.update_interval_seconds == nil
				and DEFAULTS.update_interval_seconds
			or options.update_interval_seconds,
		update_delay_seconds = options.update_delay_seconds == nil and DEFAULTS.update_delay_seconds
			or options.update_delay_seconds,
		binary_path = options.binary_path or DEFAULTS.binary_path,
		now = options.now or os.time,
		status_bg = options.status_bg == nil and DEFAULTS.status_bg or options.status_bg,
		mode_styles = options.mode_styles,
		show_git_for_pane = options.show_git_for_pane,
		on_reload = options.on_reload,
		time_format = options.time_format or DEFAULTS.time_format,
		repo_prefix = options.repo_prefix or DEFAULTS.repo_prefix,
		ref_prefix = options.ref_prefix or DEFAULTS.ref_prefix,
		worktree_text = options.worktree_text or DEFAULTS.worktree_text,
		time_prefix = options.time_prefix or DEFAULTS.time_prefix,
		time_suffix = options.time_suffix or DEFAULTS.time_suffix,
		colors = colors,
	}
end

local last_update_by_pane = {}

local function decode_percent(value)
	return value:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end)
end

local function wezterm_hostname()
	if not wezterm.hostname then
		return nil
	end
	local ok, value = pcall(wezterm.hostname)
	if ok and value and value ~= "" then
		return value
	end
	return nil
end

local function is_local_host(host)
	if not host or host == "" or host == "localhost" or host == "127.0.0.1" or host == "::1" then
		return true
	end
	local hostname = wezterm_hostname() or os.getenv("HOSTNAME")
	if not hostname or hostname == "" then
		return false
	end
	local function short_host(name)
		return name:match("^[^.]+")
	end
	return host == hostname or short_host(host) == short_host(hostname)
end

local function decode_uri_path(value)
	local host, path = value:match("^file://([^/]*)(/.*)$")
	if path then
		if not is_local_host(host) then
			return nil
		end
		return decode_percent(path)
	end
	if value:match("^file://") then
		return nil
	end
	return decode_percent(value)
end

local function cwd_path(cwd)
	if not cwd then
		return nil
	end
	if type(cwd) == "string" then
		if cwd:match("^file://") then
			return decode_uri_path(cwd)
		end
		return cwd
	end
	if cwd.scheme and cwd.scheme ~= "file" then
		return nil
	end
	if not is_local_host(cwd.host) then
		return nil
	end
	if cwd.file_path then
		local file_path = cwd.file_path
		if type(file_path) == "function" then
			local ok, value = pcall(function()
				return cwd:file_path()
			end)
			if ok then
				return value
			end
		elseif type(file_path) == "string" then
			return file_path
		end
	end
	return cwd.path and decode_uri_path(cwd.path) or nil
end

local function pane_cwd(pane)
	if not pane or not pane.get_current_working_dir then
		return nil
	end
	local ok, cwd = pcall(function()
		return pane:get_current_working_dir()
	end)
	if not ok then
		return nil
	end
	return cwd_path(cwd)
end

local function pane_id(pane)
	if not pane or not pane.pane_id then
		return nil
	end
	local ok, id = pcall(function()
		return pane:pane_id()
	end)
	if not ok or id == nil then
		return nil
	end
	return tostring(id)
end

local function refresh(pane, options)
	if not options.auto_update then
		return false
	end
	local id = pane_id(pane)
	local cwd = pane_cwd(pane)
	if not id or not cwd or cwd == "" then
		return false
	end
	if not wezterm.background_child_process then
		return false
	end

	local now = options.now()
	local last = last_update_by_pane[id]
	if last and last.cwd == cwd and now - last.at < options.update_interval_seconds then
		return false
	end
	last_update_by_pane[id] = { at = now, cwd = cwd }

	local args = {
		options.binary_path,
		"update",
		"--pane-id",
		id,
		"--cwd",
		cwd,
	}
	if options.cache_dir and options.cache_dir ~= "" then
		table.insert(args, "--cache-dir")
		table.insert(args, options.cache_dir)
	end
	local ok = pcall(wezterm.background_child_process, args)
	return ok
end

local function split_tabs(value)
	local fields = {}
	for field in (value .. "\t"):gmatch("([^\t]*)\t") do
		table.insert(fields, field)
	end
	return fields
end

local function parse_payload(value)
	if not value or value == "" then
		return nil
	end

	local fields = split_tabs(value)
	if fields[1] ~= "herdrgit1" then
		return nil
	end

	local at = tonumber(fields[2])
	local present = fields[5] == "1"
	local info = {
		at = at,
		herdr_pane_id = fields[3] or "",
		cwd = fields[4] or "",
		present = present,
		repo = present and fields[6] or nil,
		ref = present and fields[7] or nil,
		flags = fields[8] or "",
	}

	if not at then
		return nil
	end
	if present and (not info.repo or info.repo == "" or not info.ref or info.ref == "") then
		return nil
	end
	return info
end

local function cache_dir(options)
	if options.cache_dir and options.cache_dir ~= "" then
		return options.cache_dir
	end
	local xdg_cache_home = os.getenv("XDG_CACHE_HOME")
	if xdg_cache_home and xdg_cache_home ~= "" then
		return xdg_cache_home .. "/wezterm"
	end
	return (os.getenv("HOME") or "") .. "/.cache/wezterm"
end

local function read_line(path)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local value = file:read("*l")
	file:close()
	return value
end

local function focused_cache_path(options)
	return cache_dir(options) .. "/herdr-git-info"
end

local function pane_cache_path(options, pane_id)
	local sanitized = pane_id:gsub("/", "_")
	if sanitized == "" or sanitized:match("^%.+$") then
		sanitized = "_"
	end
	return cache_dir(options) .. "/herdr-git-info-by-pane/" .. sanitized
end

local function is_fresh(info, options)
	if not info then
		return false
	end
	if options.max_age_seconds == false then
		return true
	end
	return options.now() - info.at <= options.max_age_seconds
end

local function read_git_info(options)
	local focused = parse_payload(read_line(focused_cache_path(options)))
	if not is_fresh(focused, options) then
		return nil
	end
	if focused.herdr_pane_id == "" then
		if focused.present then
			return focused
		end
		return nil
	end

	local pane = parse_payload(read_line(pane_cache_path(options, focused.herdr_pane_id)))
	if pane and is_fresh(pane, options) and pane.herdr_pane_id == focused.herdr_pane_id and pane.at >= focused.at then
		if pane.present then
			return pane
		end
		return nil
	end
	if focused.present then
		return focused
	end
	return nil
end

local function push_separator(segments, options)
	table.insert(segments, { Foreground = { Color = options.colors.muted } })
	table.insert(segments, { Text = options.separator })
end

local function push_git_status(segments, info, options)
	table.insert(segments, { Foreground = { Color = options.colors.repo } })
	table.insert(segments, { Text = options.repo_prefix .. info.repo })
	push_separator(segments, options)

	if info.flags:find("w") then
		table.insert(segments, { Foreground = { Color = options.colors.worktree } })
		table.insert(segments, { Text = options.worktree_text })
	end

	local ref_color = info.flags:find("D") and options.colors.detached or options.colors.ref
	table.insert(segments, { Foreground = { Color = ref_color } })
	table.insert(segments, { Text = options.ref_prefix .. info.ref })

	if info.flags:find("d") then
		table.insert(segments, { Foreground = { Color = options.colors.dirty } })
		table.insert(segments, { Text = " *" })
	end
	if info.flags:find("R") then
		table.insert(segments, { Foreground = { Color = options.colors.detached } })
		table.insert(segments, { Text = " REBASE" })
	end
	if info.flags:find("C") then
		table.insert(segments, { Foreground = { Color = options.colors.detached } })
		table.insert(segments, { Text = " PICK" })
	end
end

local function git_segments(options)
	local segments = {}
	local info = read_git_info(options)

	if info then
		push_git_status(segments, info, options)
	end

	return segments, info
end

function M.git_segments(options)
	return git_segments(merge_options(options))
end

local function time_segments(options)
	return {
		{ Foreground = { Color = options.colors.time } },
		{ Text = options.time_prefix .. wezterm.strftime(options.time_format) .. options.time_suffix },
	}
end

function M.time_segments(options)
	return time_segments(merge_options(options))
end

function M.push_separator(segments, options)
	push_separator(segments, merge_options(options))
end

function M.refresh(pane, options)
	return refresh(pane, merge_options(options))
end

local function mode_segments(window, options)
	local segments = {}
	local ok, active_key_table = pcall(function()
		return window:active_key_table()
	end)
	if not ok then
		active_key_table = nil
	end
	local style = options.mode_styles and options.mode_styles[active_key_table] or nil

	if not style then
		return segments
	end

	table.insert(segments, { Background = { Color = style.bg } })
	table.insert(segments, { Foreground = { Color = style.fg } })
	table.insert(segments, { Attribute = { Intensity = "Bold" } })
	table.insert(segments, { Text = style.label })
	table.insert(segments, "ResetAttributes")
	if options.status_bg then
		table.insert(segments, { Background = { Color = options.status_bg } })
	end

	return segments
end

function M.mode_segments(window, options)
	return mode_segments(window, merge_options(options))
end

local function status_segments(window, pane, options)
	local segments = mode_segments(window, options)
	local show_git = not options.show_git_for_pane or options.show_git_for_pane(pane)

	if show_git then
		local git_status_segments = git_segments(options)
		if #git_status_segments > 0 then
			if #segments > 0 then
				push_separator(segments, options)
			end
			for _, segment in ipairs(git_status_segments) do
				table.insert(segments, segment)
			end
		end
	end

	if options.show_time then
		if #segments > 0 or options.always_show_time_separator then
			push_separator(segments, options)
		end
		for _, segment in ipairs(time_segments(options)) do
			table.insert(segments, segment)
		end
	end

	return segments
end

function M.segments(window, pane, options)
	return status_segments(window, pane, merge_options(options))
end

local function render(window, pane, options)
	local segments = status_segments(window, pane, options)
	window:set_right_status(wezterm.format(segments))
end

local function schedule_render(window, pane, options)
	if not options.update_delay_seconds or options.update_delay_seconds <= 0 then
		return
	end
	if not wezterm.time or not wezterm.time.call_after then
		return
	end
	wezterm.time.call_after(options.update_delay_seconds, function()
		render(window, pane, options)
	end)
end

local function window_is_focused(window)
	if not window or not window.is_focused then
		return true
	end
	local ok, focused = pcall(function()
		return window:is_focused()
	end)
	if not ok then
		return true
	end
	return focused
end

local function refresh_and_render(window, pane, options)
	local updated = false
	if window_is_focused(window) then
		updated = refresh(pane, options)
	end
	render(window, pane, options)
	if updated then
		schedule_render(window, pane, options)
	end
end

function M.render(window, pane, options)
	if options == nil and (pane == nil or type(pane) == "table") then
		options = pane
		pane = nil
	end
	render(window, pane, merge_options(options))
end

function M.setup(options)
	if M._setup_done then
		return
	end
	M._setup_done = true

	local merged = merge_options(options)
	wezterm.on("update-right-status", function(window, pane)
		refresh_and_render(window, pane, merged)
	end)
	wezterm.on("render-right-status", function(window, pane)
		local active_pane = pane or window:active_pane()
		refresh_and_render(window, active_pane, merged)
	end)
	wezterm.on("window-focus-changed", function(window, pane)
		refresh_and_render(window, pane, merged)
	end)
	wezterm.on("window-config-reloaded", function(window, pane)
		local active_pane = pane or window:active_pane()
		if merged.on_reload then
			merged.on_reload(window, active_pane)
		end
		refresh_and_render(window, active_pane, merged)
	end)
end

return M
