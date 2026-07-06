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

local function shell_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function mkdir(path)
	assert(os.execute("mkdir -p -- " .. shell_quote(path)))
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

local function render_with_options(cache, options)
	local captured = nil
	local window = {
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	options.cache_dir = cache
	right_status.render(window, options)

	return captured
end

local function render_full(cache, now, active_key_table, pane)
	local captured = nil
	local window = {
		active_key_table = function()
			return active_key_table
		end,
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	right_status.render(window, pane, {
		cache_dir = cache,
		now = function()
			return now
		end,
		separator = " / ",
		status_bg = "#111111",
		mode_styles = {
			herdr = { bg = "#222222", fg = "#eeeeee", label = " HERDR " },
		},
		show_git_for_pane = function(value)
			return value and value.is_herdr
		end,
		always_show_time_separator = true,
	})

	return captured
end

local function git_segments(cache, now)
	return right_status.git_segments({
		cache_dir = cache,
		now = function()
			return now
		end,
	})
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

local default_separator = "  \u{e0b3}  "

local function renders_focused_payload()
	local cache = cache_dir("focused")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(segment_text(render(cache, 120)), "  repo" .. default_separator .. " main *", "focused payload")
end

local function hides_stale_payload()
	local cache = cache_dir("stale")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(segment_text(render(cache, 500)), "", "stale payload")
end

local function can_disable_stale_payload_ttl()
	local cache = cache_dir("stale-disabled")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(
		segment_text(render_with_options(cache, {
			max_age_seconds = false,
			now = function()
				return 500
			end,
			show_time = false,
		})),
		"  repo" .. default_separator .. " main",
		"stale payload with ttl disabled"
	)
end

local function ignores_invalid_payloads()
	local cache = cache_dir("invalid-payload")
	write_file(cache .. "/herdr-git-info", "wrong\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(segment_text(render(cache, 120)), "", "invalid tag")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\t\tmain\t\n")
	assert_equal(segment_text(render(cache, 120)), "", "missing repo")
end

local function prefers_newer_per_pane_payload()
	local cache = cache_dir("per-pane")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t120\tpane1\t/repo\t1\trepo\tfeature\tw\n")

	assert_equal(segment_text(render(cache, 130)), "  repo" .. default_separator .. "󰙅  feature", "per-pane payload")
end

local function uses_sanitized_per_pane_path()
	local cache = cache_dir("dot-pane")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\t..\t/repo\t1\trepo\tmain\t\n")
	write_file(cache .. "/herdr-git-info-by-pane/_", "herdrgit1\t120\t..\t/repo\t1\trepo\tfeature\t\n")

	assert_equal(segment_text(render(cache, 130)), "  repo" .. default_separator .. " feature", "sanitized per-pane path")
end

local function uses_slash_sanitized_per_pane_path()
	local cache = cache_dir("slash-pane")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tw1/p1\t/repo\t1\trepo\tmain\t\n")
	write_file(cache .. "/herdr-git-info-by-pane/w1_p1", "herdrgit1\t120\tw1/p1\t/repo\t1\trepo\tfeature\t\n")

	assert_equal(segment_text(render(cache, 130)), "  repo" .. default_separator .. " feature", "slash pane path")
end

local function exposes_composable_git_segments()
	local cache = cache_dir("segments")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	local segments, info = git_segments(cache, 120)

	assert_equal(info.repo, "repo", "segment info repo")
	assert_equal(segment_text(segments), "  repo" .. default_separator .. " main *", "segment text")
end

local function renders_detached_rebase_and_pick_flags()
	local cache = cache_dir("flags")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tdeadbee\tDRC\n")

	assert_equal(
		segment_text(render(cache, 120)),
		"  repo" .. default_separator .. " deadbee REBASE PICK",
		"detached rebase pick flags"
	)
end

local function treats_two_argument_table_as_options()
	local cache = cache_dir("two-arg-options")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(
		segment_text(render_with_options(cache, {
			separator = " / ",
			now = function()
				return 120
			end,
			show_time = false,
		})),
		"  repo /  main",
		"two argument options"
	)
end

local function renders_mode_git_and_time()
	local cache = cache_dir("full")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(
		segment_text(render_full(cache, 120, "herdr", { is_herdr = true })),
		" HERDR  /   repo /  main * /  Mon Jan 1 00:00  ",
		"mode git time"
	)
end

local function hides_git_when_pane_filter_rejects()
	local cache = cache_dir("pane-filter")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(
		segment_text(render_full(cache, 120, "herdr", { is_herdr = false })),
		" HERDR  /  Mon Jan 1 00:00  ",
		"pane filter"
	)
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

	assert_equal(#_G.wezterm_handlers, 4, "registered handlers")
end

local function render_generated_cache(cache, now)
	return segment_text(render_with_options(cache, {
		now = function()
			return now
		end,
		show_time = false,
	}))
end

local function generated_git_text(repo, ref, dirty)
	local text = "  " .. repo .. default_separator .. " " .. ref
	if dirty then
		return text .. " *"
	end
	return text
end

local function run_e2e_assertions()
	assert_equal(
		render_generated_cache(arg[3], tonumber(arg[4])),
		generated_git_text(arg[5], arg[6], false),
		"e2e clean repository"
	)
	assert_equal(
		render_generated_cache(arg[7], tonumber(arg[8])),
		generated_git_text(arg[9], arg[10], true),
		"e2e dirty repository"
	)
	assert_equal(render_generated_cache(arg[11], tonumber(arg[12])), "", "e2e non-repository")
	assert_equal(
		render_generated_cache(arg[13], tonumber(arg[14])),
		generated_git_text(arg[15], arg[16], false),
		"e2e plain wezterm pane"
	)
end

local function run_unit_assertions()
	renders_focused_payload()
	hides_stale_payload()
	can_disable_stale_payload_ttl()
	ignores_invalid_payloads()
	prefers_newer_per_pane_payload()
	uses_sanitized_per_pane_path()
	uses_slash_sanitized_per_pane_path()
	exposes_composable_git_segments()
	renders_detached_rebase_and_pick_flags()
	treats_two_argument_table_as_options()
	renders_mode_git_and_time()
	hides_git_when_pane_filter_rejects()
	hides_absent_payload()
	setup_is_idempotent()
end

if arg[2] == "--e2e" then
	run_e2e_assertions()
else
	run_unit_assertions()
end
