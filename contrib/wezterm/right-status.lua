local wezterm = require("wezterm")
local io = require("io")
local os = require("os")

local M = {}

local DEFAULTS = {
	separator = " | ",
	show_time = true,
	max_age_seconds = 300,
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
		cache_dir = options.cache_dir,
		max_age_seconds = options.max_age_seconds == nil and DEFAULTS.max_age_seconds or options.max_age_seconds,
		now = options.now or os.time,
		colors = colors,
	}
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
	return cache_dir(options) .. "/herdr-git-info-by-pane/" .. pane_id:gsub("/", "_")
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
	if not focused or focused.herdr_pane_id == "" then
		if focused and focused.present then
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
	table.insert(segments, { Text = " " .. info.repo })
	push_separator(segments, options)

	if info.flags:find("w") then
		table.insert(segments, { Foreground = { Color = options.colors.worktree } })
		table.insert(segments, { Text = "wt " })
	end

	local ref_color = info.flags:find("D") and options.colors.detached or options.colors.ref
	table.insert(segments, { Foreground = { Color = ref_color } })
	table.insert(segments, { Text = info.ref })

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

function M.render(window, options)
	options = merge_options(options)
	local segments = {}
	local info = read_git_info(options)

	if info then
		push_git_status(segments, info, options)
	end

	if options.show_time then
		if #segments > 0 then
			push_separator(segments, options)
		end
		table.insert(segments, { Foreground = { Color = options.colors.time } })
		table.insert(segments, { Text = " " .. wezterm.strftime("%a %b %e %H:%M") .. " " })
	end

	window:set_right_status(wezterm.format(segments))
end

function M.setup(options)
	if M._setup_done then
		return
	end
	M._setup_done = true

	local merged = merge_options(options)
	wezterm.on("update-right-status", function(window, _)
		M.render(window, merged)
	end)
	wezterm.on("window-focus-changed", function(window, _)
		M.render(window, merged)
	end)
	wezterm.on("window-config-reloaded", function(window, _)
		M.render(window, merged)
	end)
end

return M
