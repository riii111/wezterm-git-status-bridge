package.preload["wezterm"] = function()
	return {
		format = function(segments)
			return segments
		end,
		on = function(name, callback)
			_G.wezterm_handlers = _G.wezterm_handlers or {}
			table.insert(_G.wezterm_handlers, { name = name, callback = callback })
		end,
		background_child_process = function(args)
			_G.wezterm_background_processes = _G.wezterm_background_processes or {}
			table.insert(_G.wezterm_background_processes, args)
		end,
		hostname = function()
			return "local-host"
		end,
		strftime = function()
			return "Mon Jan 1 00:00"
		end,
		time = {
			call_after = function(delay, callback)
				_G.wezterm_timers = _G.wezterm_timers or {}
				table.insert(_G.wezterm_timers, { delay = delay, callback = callback })
			end,
		},
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

local function handler(name)
	for _, candidate in ipairs(_G.wezterm_handlers or {}) do
		if candidate.name == name then
			return candidate.callback
		end
	end
	error("missing handler: " .. name, 2)
end

local function cache_dir(name)
	local path = base_dir .. "/" .. name
	mkdir(path .. "/herdr-git-info-by-pane")
	mkdir(path .. "/herdr-git-info-by-cwd")
	return path
end

local function cwd_cache_key(cwd)
	local hash = 2166136261
	for index = 1, #cwd do
		hash = (hash ~ string.byte(cwd, index)) & 0xffffffff
		hash = (hash * 16777619) & 0xffffffff
	end
	return string.format("%08x", hash)
end

local function pane_stub(id, cwd)
	return {
		pane_id = function()
			return id
		end,
		get_current_working_dir = function()
			return cwd
		end,
	}
end

local function render(cache, now, pane)
	local captured = nil
	local window = {
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	right_status.render(window, pane, {
		cache_dir = cache,
		now = function()
			return now
		end,
		show_time = false,
	})

	return captured
end

local function render_with_pane(cache, pane, options)
	local captured = nil
	local window = {
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	options.cache_dir = cache
	right_status.render(window, pane, options)

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

local function git_segments(cache, now, pane)
	return right_status.git_segments({
		cache_dir = cache,
		now = function()
			return now
		end,
		pane = pane,
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
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(
		segment_text(render(cache, 120, pane_stub("pane1", "/repo"))),
		"  repo" .. default_separator .. " main *",
		"focused payload"
	)
end

local function hides_stale_payload()
	local cache = cache_dir("stale")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(segment_text(render(cache, 500, pane_stub("pane1", "/repo"))), "", "stale payload")
end

local function can_disable_stale_payload_ttl()
	local cache = cache_dir("stale-disabled")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub("pane1", "/repo"), {
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
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "wrong\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(segment_text(render(cache, 120, pane_stub("pane1", "/repo"))), "", "invalid tag")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\t\tmain\t\n")
	assert_equal(segment_text(render(cache, 120, pane_stub("pane1", "/repo"))), "", "missing repo")
end

local function prefers_newer_per_pane_payload()
	local cache = cache_dir("per-pane")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo"),
		"herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t120\tpane1\t/repo\t1\trepo\tfeature\tw\n")

	assert_equal(
		segment_text(render(cache, 130, pane_stub("pane1", "/repo"))),
		"  repo" .. default_separator .. "󰙅  feature",
		"per-pane payload"
	)
end

local function uses_sanitized_per_pane_path()
	local cache = cache_dir("dot-pane")
	write_file(cache .. "/herdr-git-info-by-pane/_", "herdrgit1\t120\t..\t/repo\t1\trepo\tfeature\t\n")

	assert_equal(
		segment_text(render(cache, 130, pane_stub("..", "/repo"))),
		"  repo" .. default_separator .. " feature",
		"sanitized per-pane path"
	)
end

local function uses_slash_sanitized_per_pane_path()
	local cache = cache_dir("slash-pane")
	write_file(cache .. "/herdr-git-info-by-pane/w1_p1", "herdrgit1\t120\tw1/p1\t/repo\t1\trepo\tfeature\t\n")

	assert_equal(
		segment_text(render(cache, 130, pane_stub("w1/p1", "/repo"))),
		"  repo" .. default_separator .. " feature",
		"slash pane path"
	)
end

local function prefers_current_pane_cache_over_cwd_cache()
	local cache = cache_dir("current-pane")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-current"),
		"herdrgit1\t200\t3\t/repo-current\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t210\t55\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(55, "/repo-current"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"  current-repo" .. default_separator .. " feature",
		"current pane cache"
	)
end

local function current_pane_cwd_mismatch_still_uses_pane_cache()
	local cache = cache_dir("current-pane-cwd-mismatch")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-old"),
		"herdrgit1\t200\t3\t/repo-old\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t210\t55\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(55, "/repo-old"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"  current-repo" .. default_separator .. " feature",
		"current pane cwd mismatch"
	)
end

local function current_pane_absent_status_hides_cwd_cache()
	local cache = cache_dir("current-pane-absent")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/not-git"),
		"herdrgit1\t200\t3\t/not-git\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t210\t55\t/not-git\t0\t\t\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(55, "/not-git"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"",
		"current pane absent status"
	)
end

local function stale_current_pane_cache_falls_back_to_cwd_cache()
	local cache = cache_dir("current-pane-stale")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-current"),
		"herdrgit1\t400\twE:p1\t/repo-current\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t100\t55\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(55, "/repo-current"), {
			now = function()
				return 500
			end,
			show_time = false,
		})),
		"  cwd-repo" .. default_separator .. " main",
		"stale current pane fallback"
	)
end

local function current_pane_cache_rejects_payload_id_mismatch()
	local cache = cache_dir("current-pane-id-mismatch")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-current"),
		"herdrgit1\t200\twE:p1\t/repo-current\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t210\t99\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(55, "/repo-current"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"  cwd-repo" .. default_separator .. " main",
		"current pane id mismatch"
	)
end

local function prefers_cwd_cache_when_pane_cache_is_absent()
	local cache = cache_dir("cwd-join")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-cwd"),
		"herdrgit1\t210\twE:p1\t/repo-cwd\t1\tcwd-repo\tfeature\t\n"
	)

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(0, "/repo-cwd"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"  cwd-repo" .. default_separator .. " feature",
		"cwd join"
	)
end

local function cwd_cache_rejects_payload_cwd_mismatch()
	local cache = cache_dir("cwd-mismatch")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-cwd"),
		"herdrgit1\t210\twE:p1\t/other-window\t1\tcwd-repo\tfeature\t\n"
	)

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(0, "/repo-cwd"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"",
		"cwd mismatch"
	)
end

local function does_not_use_global_cache_across_windows()
	local cache = cache_dir("no-global")
	write_file(cache .. "/herdr-git-info", "herdrgit1\t210\twE:p1\t/other-window\t1\tglobal-repo\tmain\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub(0, "/repo-current"), {
			now = function()
				return 220
			end,
			show_time = false,
		})),
		"",
		"no global fallback"
	)
end

local function exposes_composable_git_segments()
	local cache = cache_dir("segments")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	local segments, info = git_segments(cache, 120, pane_stub("pane1", "/repo"))

	assert_equal(info.repo, "repo", "segment info repo")
	assert_equal(segment_text(segments), "  repo" .. default_separator .. " main *", "segment text")
end

local function renders_detached_rebase_and_pick_flags()
	local cache = cache_dir("flags")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tdeadbee\tDRC\n")

	assert_equal(
		segment_text(render(cache, 120, pane_stub("pane1", "/repo"))),
		"  repo" .. default_separator .. " deadbee REBASE PICK",
		"detached rebase pick flags"
	)
end

local function treats_two_argument_table_as_options()
	local cache = cache_dir("two-arg-options")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\t\n")

	assert_equal(
		segment_text(render_with_pane(cache, pane_stub("pane1", "/repo"), {
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
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	local pane = pane_stub("pane1", "/repo")
	pane.is_herdr = true

	assert_equal(
		segment_text(render_full(cache, 120, "herdr", pane)),
		" HERDR  /   repo /  main * /  Mon Jan 1 00:00  ",
		"mode git time"
	)
end

local function hides_git_when_pane_filter_rejects()
	local cache = cache_dir("pane-filter")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t1\trepo\tmain\td\n")

	assert_equal(
		segment_text(render_full(cache, 120, "herdr", { is_herdr = false })),
		" HERDR  /  Mon Jan 1 00:00  ",
		"pane filter"
	)
end

local function hides_absent_payload()
	local cache = cache_dir("absent")
	write_file(cache .. "/herdr-git-info-by-pane/pane1", "herdrgit1\t100\tpane1\t/repo\t0\t\t\t\n")

	assert_equal(segment_text(render(cache, 120, pane_stub("pane1", "/repo"))), "", "absent payload")
end

local function setup_is_idempotent()
	_G.wezterm_handlers = {}
	right_status._setup_done = nil

	right_status.setup({ cache_dir = cache_dir("setup") })
	right_status.setup({ cache_dir = cache_dir("setup") })

	assert_equal(#_G.wezterm_handlers, 4, "registered handlers")
end

local function setup_refreshes_active_pane_in_background()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local cache = cache_dir("setup-refresh")
	local pane = {
		pane_id = function()
			return 42
		end,
		get_current_working_dir = function()
			return { scheme = "file", path = "/repo%20one" }
		end,
	}
	local renders = 0
	local window = {
		is_focused = function()
			return true
		end,
		set_right_status = function()
			renders = renders + 1
		end,
	}

	right_status.setup({
		cache_dir = cache,
		binary_path = "/bin/bridge",
		now = function()
			return 100
		end,
		show_time = false,
	})
	handler("update-right-status")(window, pane)

	local args = _G.wezterm_background_processes[1]
	assert_equal(args[1], "/bin/bridge", "background binary")
	assert_equal(args[2], "update", "background command")
	assert_equal(args[4], "42", "background pane id")
	assert_equal(args[6], "/repo one", "background cwd")
	assert_equal(args[8], cache, "background cache dir")
	assert_equal(renders, 1, "immediate render")
	assert_equal(#_G.wezterm_timers, 1, "delayed render timer")
	assert_equal(_G.wezterm_timers[1].delay, 0.2, "delayed render delay")
	_G.wezterm_timers[1].callback()
	assert_equal(renders, 2, "delayed render")
end

local function setup_does_not_refresh_unfocused_window()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local pane = {
		pane_id = function()
			return 45
		end,
		get_current_working_dir = function()
			return "/repo"
		end,
	}
	local renders = 0
	local window = {
		is_focused = function()
			return false
		end,
		set_right_status = function()
			renders = renders + 1
		end,
	}

	right_status.setup({
		cache_dir = cache_dir("setup-unfocused"),
		show_time = false,
	})
	handler("update-right-status")(window, pane)

	assert_equal(#_G.wezterm_background_processes, 0, "unfocused background refresh")
	assert_equal(#_G.wezterm_timers, 0, "unfocused delayed render")
	assert_equal(renders, 1, "unfocused render")
end

local function setup_throttles_background_refreshes()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local cwd = "/repo"
	local pane = {
		pane_id = function()
			return 43
		end,
		get_current_working_dir = function()
			return cwd
		end,
	}
	local window = {
		set_right_status = function() end,
	}
	local now = 100

	right_status.setup({
		cache_dir = cache_dir("setup-throttle"),
		now = function()
			return now
		end,
		show_time = false,
	})
	handler("update-right-status")(window, pane)
	now = 101
	handler("update-right-status")(window, pane)

	assert_equal(#_G.wezterm_background_processes, 1, "throttled background refresh")

	now = 102
	handler("update-right-status")(window, pane)
	assert_equal(#_G.wezterm_background_processes, 2, "refresh resumes after interval")

	cwd = "/repo-next"
	now = 103
	handler("update-right-status")(window, pane)
	assert_equal(#_G.wezterm_background_processes, 3, "cwd change refreshes within interval")
end

local function setup_can_disable_background_refreshes()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local pane = {
		pane_id = function()
			return 42
		end,
		get_current_working_dir = function()
			return "/repo"
		end,
	}
	local window = {
		set_right_status = function() end,
	}

	right_status.setup({
		cache_dir = cache_dir("setup-disabled"),
		auto_update = false,
		show_time = false,
	})
	handler("update-right-status")(window, pane)

	assert_equal(#_G.wezterm_background_processes, 0, "disabled background refresh")
end

local function update_event_without_pane_prefers_active_pane_cache()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local cache = cache_dir("update-active-pane")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-current"),
		"herdrgit1\t200\t3\t/repo-current\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/55", "herdrgit1\t210\t55\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	local pane = pane_stub(55, "/repo-current")
	local captured = nil
	local window = {
		active_pane = function()
			return pane
		end,
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	right_status.setup({
		cache_dir = cache,
		auto_update = false,
		now = function()
			return 220
		end,
		show_time = false,
	})
	handler("update-right-status")(window, nil)

	assert_equal(segment_text(captured), "  current-repo" .. default_separator .. " feature", "update event active pane")
end

local function render_without_pane_prefers_window_active_pane_cache()
	local cache = cache_dir("render-active-pane")
	write_file(
		cache .. "/herdr-git-info-by-cwd/" .. cwd_cache_key("/repo-current"),
		"herdrgit1\t200\t3\t/repo-current\t1\tcwd-repo\tmain\t\n"
	)
	write_file(cache .. "/herdr-git-info-by-pane/56", "herdrgit1\t210\t56\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	local pane = pane_stub(56, "/repo-current")
	local captured = nil
	local window = {
		active_pane = function()
			return pane
		end,
		set_right_status = function(_, segments)
			captured = segments
		end,
	}

	right_status.render(window, {
		cache_dir = cache,
		now = function()
			return 220
		end,
		show_time = false,
	})

	assert_equal(segment_text(captured), "  current-repo" .. default_separator .. " feature", "render active pane")
end

local function refresh_skips_mismatched_cached_cwd()
	_G.wezterm_background_processes = {}
	local cache = cache_dir("refresh-cached-cwd-mismatch")
	write_file(cache .. "/herdr-git-info-by-pane/57", "herdrgit1\t210\t57\t/repo-current\t1\tcurrent-repo\tfeature\t\n")

	local pane = {
		pane_id = function()
			return 57
		end,
		get_current_working_dir = function()
			return "/repo-old"
		end,
	}

	local launched = right_status.refresh(pane, {
		cache_dir = cache,
		now = function()
			return 220
		end,
	})

	assert_equal(launched, false, "refresh cached cwd mismatch")
	assert_equal(#_G.wezterm_background_processes, 0, "refresh cached cwd mismatch process count")
end

local function refresh_allows_cwd_change_from_own_cached_cwd()
	_G.wezterm_background_processes = {}
	local cache = cache_dir("refresh-own-cached-cwd-change")
	local cwd = "/repo-old"
	local pane = {
		pane_id = function()
			return 58
		end,
		get_current_working_dir = function()
			return cwd
		end,
	}
	local now = 220
	local options = {
		cache_dir = cache,
		now = function()
			return now
		end,
	}

	local launched = right_status.refresh(pane, options)
	assert_equal(launched, true, "initial refresh")
	write_file(cache .. "/herdr-git-info-by-pane/58", "herdrgit1\t220\t58\t/repo-old\t1\told-repo\tmain\t\n")

	cwd = "/repo-next"
	now = 221
	launched = right_status.refresh(pane, options)

	assert_equal(launched, true, "refresh own cached cwd change")
	assert_equal(#_G.wezterm_background_processes, 2, "refresh own cached cwd change process count")
	assert_equal(_G.wezterm_background_processes[2][6], "/repo-next", "refresh own cached cwd change cwd")
end

local function refresh_without_background_api_does_not_throttle()
	_G.wezterm_background_processes = {}
	local wezterm_module = package.loaded.wezterm
	local original_background_child_process = wezterm_module.background_child_process
	local cache = cache_dir("missing-background-api")
	local pane = {
		pane_id = function()
			return 44
		end,
		get_current_working_dir = function()
			return "/repo"
		end,
	}
	local now = 100

	wezterm_module.background_child_process = nil
	local launched = right_status.refresh(pane, {
		cache_dir = cache,
		now = function()
			return now
		end,
	})
	assert_equal(launched, false, "missing background api")

	wezterm_module.background_child_process = original_background_child_process
	launched = right_status.refresh(pane, {
		cache_dir = cache,
		now = function()
			return now
		end,
	})
	assert_equal(launched, true, "retry after background api returns")
	assert_equal(#_G.wezterm_background_processes, 1, "retry process count")
end

local function refresh_rejects_remote_cwd()
	_G.wezterm_background_processes = {}
	local cache = cache_dir("refresh-cwd")
	local remote_file_pane = {
		pane_id = function()
			return 46
		end,
		get_current_working_dir = function()
			return { scheme = "file", host = "remote-host", path = "/repo" }
		end,
	}
	local non_file_pane = {
		pane_id = function()
			return 47
		end,
		get_current_working_dir = function()
			return {
				scheme = "ssh",
				host = "remote-host",
				file_path = function()
					return "/repo"
				end,
			}
		end,
	}
	local local_file_pane = {
		pane_id = function()
			return 48
		end,
		get_current_working_dir = function()
			return { scheme = "file", host = "local-host", path = "/repo%20one" }
		end,
	}
	local plain_percent_path_pane = {
		pane_id = function()
			return 53
		end,
		get_current_working_dir = function()
			return "/repo%41"
		end,
	}
	local local_fqdn_pane = {
		pane_id = function()
			return 49
		end,
		get_current_working_dir = function()
			return { scheme = "file", host = "local-host.example.com", path = "/repo%20two" }
		end,
	}
	local malformed_file_uri_pane = {
		pane_id = function()
			return 50
		end,
		get_current_working_dir = function()
			return "file://remote-host"
		end,
	}
	local local_short_from_fqdn_pane = {
		pane_id = function()
			return 51
		end,
		get_current_working_dir = function()
			return { scheme = "file", host = "local-host", path = "/repo%20three" }
		end,
	}
	local wezterm_module = package.loaded.wezterm
	local original_hostname = wezterm_module.hostname

	assert_equal(right_status.refresh(remote_file_pane, { cache_dir = cache }), false, "remote file cwd")
	assert_equal(right_status.refresh(non_file_pane, { cache_dir = cache }), false, "non-file cwd")
	assert_equal(right_status.refresh(malformed_file_uri_pane, { cache_dir = cache }), false, "malformed file uri")
	assert_equal(right_status.refresh(local_file_pane, { cache_dir = cache }), true, "local file cwd")
	assert_equal(right_status.refresh(plain_percent_path_pane, { cache_dir = cache }), true, "plain percent path")
	assert_equal(right_status.refresh(local_fqdn_pane, { cache_dir = cache }), true, "local fqdn cwd")
	wezterm_module.hostname = function()
		return "local-host.example.com"
	end
	assert_equal(right_status.refresh(local_short_from_fqdn_pane, { cache_dir = cache }), true, "local short cwd from fqdn hostname")
	wezterm_module.hostname = original_hostname
	assert_equal(#_G.wezterm_background_processes, 4, "local refresh count")
	assert_equal(_G.wezterm_background_processes[1][6], "/repo one", "local decoded cwd")
	assert_equal(_G.wezterm_background_processes[2][6], "/repo%41", "plain percent cwd")
	assert_equal(_G.wezterm_background_processes[3][6], "/repo two", "local fqdn decoded cwd")
	assert_equal(_G.wezterm_background_processes[4][6], "/repo three", "local short decoded cwd")
end

local function render_event_uses_active_pane_fallback()
	_G.wezterm_handlers = {}
	_G.wezterm_background_processes = {}
	_G.wezterm_timers = {}
	right_status._setup_done = nil

	local pane = {
		pane_id = function()
			return 52
		end,
		get_current_working_dir = function()
			return "/repo"
		end,
	}
	local window = {
		active_pane = function()
			return pane
		end,
		is_focused = function()
			return true
		end,
		set_right_status = function() end,
	}

	right_status.setup({
		cache_dir = cache_dir("render-event"),
		show_time = false,
	})
	handler("render-right-status")(window, nil)

	assert_equal(#_G.wezterm_background_processes, 1, "render event active pane refresh")
	assert_equal(_G.wezterm_background_processes[1][4], "52", "render event pane id")
end

local function render_generated_cache(cache, now, pane_id, cwd)
	return segment_text(render_with_pane(cache, pane_stub(pane_id, cwd), {
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
		render_generated_cache(arg[3], tonumber(arg[4]), arg[5], arg[6]),
		generated_git_text(arg[7], arg[8], false),
		"e2e clean repository"
	)
	assert_equal(
		render_generated_cache(arg[9], tonumber(arg[10]), arg[11], arg[12]),
		generated_git_text(arg[13], arg[14], true),
		"e2e dirty repository"
	)
	assert_equal(render_generated_cache(arg[15], tonumber(arg[16]), arg[17], arg[18]), "", "e2e non-repository")
	assert_equal(
		render_generated_cache(arg[19], tonumber(arg[20]), arg[21], arg[22]),
		generated_git_text(arg[23], arg[24], false),
		"e2e plain wezterm pane"
	)
	assert_equal(
		render_generated_cache(arg[25], tonumber(arg[26]), arg[27], arg[28]),
		generated_git_text(arg[29], arg[30], false),
		"e2e cwd join"
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
	prefers_current_pane_cache_over_cwd_cache()
	current_pane_cwd_mismatch_still_uses_pane_cache()
	current_pane_absent_status_hides_cwd_cache()
	stale_current_pane_cache_falls_back_to_cwd_cache()
	current_pane_cache_rejects_payload_id_mismatch()
	prefers_cwd_cache_when_pane_cache_is_absent()
	cwd_cache_rejects_payload_cwd_mismatch()
	does_not_use_global_cache_across_windows()
	exposes_composable_git_segments()
	renders_detached_rebase_and_pick_flags()
	treats_two_argument_table_as_options()
	renders_mode_git_and_time()
	hides_git_when_pane_filter_rejects()
	hides_absent_payload()
	setup_is_idempotent()
	setup_refreshes_active_pane_in_background()
	setup_does_not_refresh_unfocused_window()
	setup_throttles_background_refreshes()
	setup_can_disable_background_refreshes()
	update_event_without_pane_prefers_active_pane_cache()
	render_without_pane_prefers_window_active_pane_cache()
	refresh_skips_mismatched_cached_cwd()
	refresh_allows_cwd_change_from_own_cached_cwd()
	refresh_without_background_api_does_not_throttle()
	refresh_rejects_remote_cwd()
	render_event_uses_active_pane_fallback()
end

if arg[2] == "--e2e" then
	run_e2e_assertions()
else
	run_unit_assertions()
end
