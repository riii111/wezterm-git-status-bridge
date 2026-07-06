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

clean_repo="$tmp/clean-repo"
dirty_repo="$tmp/dirty-repo"
non_repo="$tmp/non-repo"
clean_cache="$tmp/cache-clean"
dirty_cache="$tmp/cache-dirty"
non_repo_cache="$tmp/cache-non-repo"
plain_cache="$tmp/cache-plain"
lua_scratch="$tmp/lua"

setup_repo "$clean_repo"
setup_repo "$dirty_repo"
mkdir -p "$non_repo" "$lua_scratch"
printf 'scratch\n' > "$dirty_repo/scratch.txt"

run_update "$clean_cache" "$clean_repo" "$pane_id" "$sanitized_pane_id"
run_update "$dirty_cache" "$dirty_repo" "$pane_id" "$sanitized_pane_id"
run_update "$non_repo_cache" "$non_repo" "$pane_id" "$sanitized_pane_id"
run_update "$plain_cache" "$clean_repo" "" "_"
poison_global_cache "$clean_cache"
poison_global_cache "$dirty_cache"

"$lua_bin" "$root/tests/right-status.lua" "$lua_scratch" --e2e \
	"$clean_cache" "$(cache_now "$clean_cache")" clean-repo main \
	"$dirty_cache" "$(cache_now "$dirty_cache")" dirty-repo main \
	"$non_repo_cache" "$(cache_now "$non_repo_cache")" \
	"$plain_cache" "$(cache_now "$plain_cache")" clean-repo main
