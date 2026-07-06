package.preload["wezterm"] = function()
	return {
		format = function(segments)
			return segments
		end,
		on = function(name, callback)
			_G.wezterm_handlers = _G.wezterm_handlers or {}
			table.insert(_G.wezterm_handlers, { name = name, callback = callback })
		end,
		strftime = function()
			return "Mon Jan 1 00:00"
		end,
	}
end

package.path = "contrib/wezterm/?.lua;" .. package.path

local right_status = require("right-status")
local base_dir = assert(arg[1], "cache base dir argument is required")

local function assert_equal(actual, expected, label)
	if actual ~= expected then
		error(label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
	end
end

local function mkdir(path)
	assert(os.execute("mkdir -p " .. path))
end

local function write_file(path, contents)
	local file = assert(io.open(path, "w"))
	file:write(contents)
	file:close()
end

local function cache_dir(name)
	local path = base_dir .. "/" .. name
	mkdir(path .. "/herdr-git-info-by-pane")
	return path
end

local function render(cache, now)
	local captured = nil
	local window = {
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	right_status.render(window, {
		cache_dir = cache,
		now = function()
			return now
		end,
		show_time = false,
	})

	return captured
end

local function segment_text(segments)
	local parts = {}
	for _, segment in ipairs(segments) do
		if segment.Text then
			table.insert(parts, segment.Text)
		end
	end
	return table.concat(parts, "")
end

local function renders_focused_payload()
	local cache = cache_dir("focused")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(segment_text(render(cache, 120)), " repo | main *", "focused payload")
end

local function hides_stale_payload()
	local cache = cache_dir("stale")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(segment_text(render(cache, 500)), "", "stale payload")
end

local function prefers_newer_per_pane_payload()
	local cache = cache_dir("per-pane")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t120\tpane1\t/repo\t1\trepo\tfeature\tw\n")

	assert_equal(segment_text(render(cache, 130)), " repo | wt feature", "per-pane payload")
end

local function hides_absent_payload()
	local cache = cache_dir("absent")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t0\t\t\t\n")

	assert_equal(segment_text(render(cache, 120)), "", "absent payload")
end

local function setup_is_idempotent()
	_G.wezterm_handlers = {}
	right_status._setup_done = nil

	right_status.setup({ cache_dir = cache_dir("setup") })
	right_status.setup({ cache_dir = cache_dir("setup") })

	assert_equal(#_G.wezterm_handlers, 3, "registered handlers")
end

renders_focused_payload()
hides_stale_payload()
prefers_newer_per_pane_payload()
hides_absent_payload()
setup_is_idempotent()
