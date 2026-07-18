#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lua_bin=${LUA:-}
if [ -z "$lua_bin" ]; then
	if command -v lua5.4 >/dev/null 2>&1; then
		lua_bin=lua5.4
	else
		lua_bin=lua
	fi
fi

tmp_root=${TMPDIR:-/tmp}
tmp=$(mktemp -d "${tmp_root%/}/wezterm-git-status-bridge-e2e.XXXXXX")
trap 'rm -rf "$tmp"' EXIT INT TERM

cargo build
bin="$root/target/debug/wezterm-git-status-bridge"
pane_id="window/1:pane/2"
sanitized_pane_id="window_1:pane_2"

setup_repo() {
	repo_path=$1
	mkdir -p "$repo_path"
	git -C "$repo_path" init --initial-branch main >/dev/null
	git -C "$repo_path" config user.name "Test User"
	git -C "$repo_path" config user.email "test@example.com"
	printf 'test\n' > "$repo_path/README.md"
	git -C "$repo_path" add README.md
	git -C "$repo_path" commit -m initial >/dev/null
}

run_update() {
	cache_path=$1
	cwd_path=$2
	update_pane_id=$3
	sanitized_update_pane_id=$4
	"$bin" update --cache-dir "$cache_path" --pane-id "$update_pane_id" --cwd "$cwd_path"
	test -f "$cache_path/herdr-git-info-by-pane/$sanitized_update_pane_id"
	cwd_key=$(
		"$lua_bin" - "$root" "$cwd_path" <<'LUA'
package.preload["wezterm"] = function()
	return {}
end
package.path = arg[1] .. "/contrib/wezterm/?.lua;" .. package.path
io.write(require("right-status").cwd_cache_key(assert(arg[2])))
LUA
	)
	test -f "$cache_path/herdr-git-info-by-cwd/$cwd_key"
}

cache_now() {
	IFS='	' read -r tag at rest < "$1/herdr-git-info"
	test "$tag" = "herdrgit1"
	printf '%s\n' "$((at + 1))"
}

poison_global_cache() {
	cache_path=$1
	IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$cache_path/herdr-git-info"
	test "$tag" = "herdrgit1"
	test "$present" = "1"
	printf '%s\t%s\t%s\t%s\t1\tfallback-repo\tfallback-ref\t%s\n' \
		"$tag" "$at" "$cached_pane_id" "$cached_cwd" "$flags" > "$cache_path/herdr-git-info"
}

remove_pane_cache() {
	cache_path=$1
	sanitized_update_pane_id=$2
	rm -f "$cache_path/herdr-git-info-by-pane/$sanitized_update_pane_id"
}

clean_repo="$tmp/clean-repo"
dirty_repo="$tmp/dirty-repo"
non_repo="$tmp/non-repo"
clean_cache="$tmp/cache-clean"
dirty_cache="$tmp/cache-dirty"
non_repo_cache="$tmp/cache-non-repo"
plain_cache="$tmp/cache-plain"
cwd_join_cache="$tmp/cache-cwd-join"
plugin_cache_home="$tmp/cache-plugin"
plugin_event_cache_home="$tmp/cache-plugin-event"
plugin_env_fallback_cache_home="$tmp/cache-plugin-env-fallback"
plugin_no_focus_cache_home="$tmp/cache-plugin-no-focus"
setup_hook_cache_home="$tmp/cache-setup-hook"
setup_wezterm_dir="$tmp/setup-wezterm"
setup_zshrc="$tmp/setup-zshrc"
lua_scratch="$tmp/lua"
fake_herdr="$tmp/herdr"
missing_bin_stderr="$tmp/missing-bin.stderr"

setup_repo "$clean_repo"
setup_repo "$dirty_repo"
mkdir -p "$non_repo" "$lua_scratch"
printf 'scratch\n' > "$dirty_repo/scratch.txt"

run_update "$clean_cache" "$clean_repo" "$pane_id" "$sanitized_pane_id"
run_update "$dirty_cache" "$dirty_repo" "$pane_id" "$sanitized_pane_id"
run_update "$non_repo_cache" "$non_repo" "$pane_id" "$sanitized_pane_id"
run_update "$plain_cache" "$clean_repo" "" "_"
run_update "$cwd_join_cache" "$clean_repo" "wE:p1" "wE:p1"
poison_global_cache "$clean_cache"
poison_global_cache "$dirty_cache"
poison_global_cache "$cwd_join_cache"
remove_pane_cache "$cwd_join_cache" "wE:p1"

cat > "$fake_herdr" <<EOF
#!/usr/bin/env sh
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then
	printf '%s\n' '{"result":{"panes":[{"pane_id":"window/9:pane/3","focused":true,"foreground_cwd":"$clean_repo"}]}}'
	exit 0
fi
exit 2
EOF
chmod +x "$fake_herdr"

env -u HERDR_PLUGIN_EVENT_JSON \
	WEZTERM_GIT_STATUS_BRIDGE_BIN="$bin" \
	HERDR_BIN_PATH="$fake_herdr" \
	XDG_CACHE_HOME="$plugin_cache_home" \
	sh "$root/contrib/herdr-plugin/update-status"

plugin_cache="$plugin_cache_home/wezterm"
test -f "$plugin_cache/herdr-git-info-by-pane/window_9:pane_3"
test -f "$plugin_cache/herdr-git-info-focused"
IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$plugin_cache/herdr-git-info"
test "$tag" = "herdrgit1"
test "$cached_pane_id" = "window/9:pane/3"
test "$cached_cwd" = "$clean_repo"
test "$present" = "1"
test "$repo" = "clean-repo"
test "$ref" = "main"

"$bin" update --cache-dir "$plugin_cache" --pane-id "window/9:pane/3" --cwd "$dirty_repo"
IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$plugin_cache/herdr-git-info-focused"
test "$tag" = "herdrgit1"
test "$cached_pane_id" = "window/9:pane/3"
test "$cached_cwd" = "$dirty_repo"
test "$present" = "1"
test "$repo" = "dirty-repo"

HERDR_PLUGIN_EVENT_JSON='{"event":"pane.focused"}' \
	WEZTERM_GIT_STATUS_BRIDGE_BIN="$bin" \
	HERDR_BIN_PATH="$fake_herdr" \
	XDG_CACHE_HOME="$plugin_event_cache_home" \
	sh "$root/contrib/herdr-plugin/update-status"

plugin_event_cache="$plugin_event_cache_home/wezterm"
test -f "$plugin_event_cache/herdr-git-info-by-pane/window_9:pane_3"
test -f "$plugin_event_cache/herdr-git-info-focused"
IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$plugin_event_cache/herdr-git-info"
test "$tag" = "herdrgit1"
test "$cached_pane_id" = "window/9:pane/3"
test "$cached_cwd" = "$clean_repo"
test "$present" = "1"

cat > "$fake_herdr" <<'EOF'
#!/usr/bin/env sh
exit 2
EOF
chmod +x "$fake_herdr"

HERDR_PLUGIN_EVENT_JSON="{\"pane\":{\"pane_id\":\"window/7:pane/8\",\"cwd\":\"$clean_repo\"}}" \
	WEZTERM_GIT_STATUS_BRIDGE_BIN="$bin" \
	HERDR_BIN_PATH="$fake_herdr" \
	XDG_CACHE_HOME="$plugin_env_fallback_cache_home" \
	sh "$root/contrib/herdr-plugin/update-status"

plugin_env_fallback_cache="$plugin_env_fallback_cache_home/wezterm"
test -f "$plugin_env_fallback_cache/herdr-git-info-by-pane/window_7:pane_8"
test -f "$plugin_env_fallback_cache/herdr-git-info-focused"
IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$plugin_env_fallback_cache/herdr-git-info"
test "$tag" = "herdrgit1"
test "$cached_pane_id" = "window/7:pane/8"
test "$cached_cwd" = "$clean_repo"
test "$present" = "1"

cat > "$fake_herdr" <<EOF
#!/usr/bin/env sh
if [ "\$1" = "plugin" ] && [ "\$2" = "link" ]; then
	exit 0
fi
if [ "\$1" = "pane" ] && [ "\$2" = "list" ]; then
	printf '%s\n' '{"result":{"panes":[{"pane_id":"window/9:pane/3","focused":true,"foreground_cwd":"$clean_repo"}]}}'
	exit 0
fi
exit 2
EOF
chmod +x "$fake_herdr"

mkdir -p "$setup_wezterm_dir"
cat > "$setup_wezterm_dir/wezterm.lua" <<'EOF'
local config = {}
-- wezterm-git-status-bridge setup begin
local git_status = require("right-status")
git_status.setup({
  auto_update = true,
  binary_path = "/old/bin/wezterm-git-status-bridge",
  separator = "}",
  time_format = "function %H end",
  -- }) function end
  on_reload = function(window, pane)
    window:set_config_overrides({
      colors = {
        tab_bar = { background = "#1f2335" },
      },
    })
    window:set_right_status("mode")
  end,
  mode_styles = {
    resize = { label = "RESIZE", bg = "#7aa2f7", fg = "#1f2335" },
  },
})
-- wezterm-git-status-bridge setup end
return config
EOF

"$bin" setup --herdr --herdr-bin "$fake_herdr" --wezterm-config-dir "$setup_wezterm_dir" --zshrc "$setup_zshrc"
test -f "$setup_wezterm_dir/right-status.lua"
test -f "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'separator = "}"' "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'time_format = "function %H end"' "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'window:set_config_overrides({' "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'mode_styles = {' "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'on_reload = function(window, pane)' "$setup_wezterm_dir/wezterm.lua"
grep -q -- 'auto_update = false' "$setup_wezterm_dir/wezterm.lua"
if grep -q -- '/old/bin/wezterm-git-status-bridge' "$setup_wezterm_dir/wezterm.lua"; then
	exit 1
fi
grep -q -- '--cwd "$PWD"' "$setup_zshrc"
if grep -q -- 'pane list' "$setup_zshrc"; then
	exit 1
fi
(
	cd "$dirty_repo"
	env XDG_CACHE_HOME="$setup_hook_cache_home" HERDR_PANE_ID="w1:p1" WEZTERM_PANE="window/5:pane/6" zsh -fc ". '$setup_zshrc'; _wezterm_git_status_bridge_update"
)

setup_hook_cache="$setup_hook_cache_home/wezterm"
count=0
while [ ! -f "$setup_hook_cache/herdr-git-info" ] && [ "$count" -lt 50 ]; do
	count=$((count + 1))
	sleep 0.1
done
test -f "$setup_hook_cache/herdr-git-info"
IFS='	' read -r tag at cached_pane_id cached_cwd present repo ref flags < "$setup_hook_cache/herdr-git-info"
test "$tag" = "herdrgit1"
test "$cached_pane_id" = "w1:p1"
test "$cached_cwd" = "$dirty_repo"
test "$present" = "1"
test "$repo" = "dirty-repo"
test ! -e "$setup_hook_cache/herdr-git-info-focused"

cat > "$fake_herdr" <<'EOF'
#!/usr/bin/env sh
if [ "$1" = "pane" ] && [ "$2" = "list" ]; then
	printf '%s\n' '{"result":{"panes":[{"pane_id":"window/9:pane/3","focused":false,"foreground_cwd":"/unused"}]}}'
	exit 0
fi
exit 2
EOF
chmod +x "$fake_herdr"

env -u HERDR_PLUGIN_EVENT_JSON \
	WEZTERM_GIT_STATUS_BRIDGE_BIN="$bin" \
	HERDR_BIN_PATH="$fake_herdr" \
	XDG_CACHE_HOME="$plugin_no_focus_cache_home" \
	sh "$root/contrib/herdr-plugin/update-status"
test ! -e "$plugin_no_focus_cache_home/wezterm/herdr-git-info"
test ! -e "$plugin_no_focus_cache_home/wezterm/herdr-git-info-focused"

if env -u WEZTERM_GIT_STATUS_BRIDGE_BIN PATH="$tmp/no-bin" /bin/sh "$root/contrib/herdr-plugin/update-status" 2>"$missing_bin_stderr"; then
	exit 1
fi
grep -q "set WEZTERM_GIT_STATUS_BRIDGE_BIN or install wezterm-git-status-bridge in PATH" "$missing_bin_stderr"

"$lua_bin" "$root/tests/right-status.lua" "$lua_scratch" --e2e \
	"$clean_cache" "$(cache_now "$clean_cache")" "$pane_id" "$clean_repo" clean-repo main \
	"$dirty_cache" "$(cache_now "$dirty_cache")" "$pane_id" "$dirty_repo" dirty-repo main \
	"$non_repo_cache" "$(cache_now "$non_repo_cache")" "$pane_id" "$non_repo" \
	"$plain_cache" "$(cache_now "$plain_cache")" "" "$clean_repo" clean-repo main \
	"$cwd_join_cache" "$(cache_now "$cwd_join_cache")" "0" "$clean_repo" clean-repo main
