# wezterm-git-status-bridge

<img width="507" height="173" alt="image" src="https://github.com/user-attachments/assets/757f2ad4-c2fc-4ec1-a33c-35fccf06c1e0" />

Show Git repository status in WezTerm's right status without running `git` from WezTerm's render path.

The bridge writes Git status to a cache file, and the Lua module renders from that cache. It shows the repository, branch or detached commit, dirty state, linked worktree state, and rebase or cherry-pick state.

## Requirements

- WezTerm
- `git`
- `wezterm-git-status-bridge`

Herdr is optional. WezTerm can update the cache by itself; the Herdr plugin is only for users who want status from the focused pane inside Herdr.

## Setup on macOS

1. Install the binary and Lua module.

   ```sh
   version=v0.2.0
   arch=$(uname -m)
   case "$arch" in
     arm64) target=aarch64-apple-darwin ;;
     x86_64) target=x86_64-apple-darwin ;;
     *) echo "unsupported macOS arch: $arch" >&2; exit 1 ;;
   esac
   mkdir -p "$HOME/.local/bin"
   mkdir -p "$HOME/.config/wezterm"
   curl -L "https://github.com/riii111/wezterm-git-status-bridge/releases/download/$version/wezterm-git-status-bridge-$target.tar.gz" |
     tar xz -C /tmp
   install -m 0755 "/tmp/wezterm-git-status-bridge-$target/wezterm-git-status-bridge" "$HOME/.local/bin/"
   cp "/tmp/wezterm-git-status-bridge-$target/contrib/wezterm/right-status.lua" "$HOME/.config/wezterm/"
   ```

2. Use one of the setups below in `wezterm.lua`, then reload WezTerm.

### WezTerm only

Use this when each WezTerm pane directly runs your shell:

```lua
local git_status = require("right-status")

git_status.setup({
  binary_path = os.getenv("HOME") .. "/.local/bin/wezterm-git-status-bridge",
})
```

This updates in the background from WezTerm events. The clock is shown by default because `show_time` defaults to `true`.

### Herdr integration

Use this when the visible Git repository is the focused pane inside Herdr:

1. Install the Herdr plugin.

```sh
herdr plugin install riii111/wezterm-git-status-bridge/contrib/herdr-plugin --ref v0.2.0 --yes
```

2. Set this in `wezterm.lua`:

```lua
local git_status = require("right-status")

git_status.setup({
  auto_update = false,
  binary_path = os.getenv("HOME") .. "/.local/bin/wezterm-git-status-bridge",
})
```

The Herdr plugin updates on pane focus and workspace focus. It does not replace shell hooks for every branch switch or directory change inside a pane.

### Migrating from a shell hook

If your old setup called `wezterm-git-status-bridge update` from `chpwd` or `precmd`, keep that hook unless WezTerm-only updates cover your workflow. The command is:

```sh
wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"
```

## Notes

If you already manage `update-right-status`, refresh the cache before composing the segments:

```lua
local wezterm = require("wezterm")
local git_status = require("right-status")

wezterm.on("update-right-status", function(window, pane)
  if window:is_focused() then
    git_status.refresh(pane)
  end
  window:set_right_status(wezterm.format(git_status.segments(window, pane)))
end)
```

For a Nix one-off update:

```sh
nix run github:riii111/wezterm-git-status-bridge -- update --pane-id manual --cwd "$PWD"
```

## Troubleshooting

- If Git status is shown but does not update, run `wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"` and reload WezTerm. If that works, the missing piece is the update trigger.
- If you set `auto_update = false`, something else must write the cache. Use the Herdr plugin, a shell hook, or both.
- Herdr plugin events do not cover every shell-level `cd` or `git switch`. Keep `chpwd` / `precmd` hooks when migrating from that setup.

Common options:

| Option | Default |
| --- | --- |
| `auto_update` | `true`; set `false` when another integration writes the cache |
| `binary_path` | `WEZTERM_GIT_STATUS_BRIDGE_BIN` or `wezterm-git-status-bridge` |
| `update_interval_seconds` | `2`; minimum seconds between background updates for the same pane and directory |
| `update_delay_seconds` | `0.2`; best-effort redraw delay after a background update request |
| `max_age_seconds` | `300`; set `false` to disable TTL hiding |
| `separator` | Powerline separator with spacing |
| `show_time` | `true` |
| `colors` | Tokyo Night-inspired muted dark palette |
| `mode_styles` | `nil`; key-table labels to prepend before Git status |
| `status_bg` | `#1f1f28`; applied after a mode label, set `false` to disable |
| `show_git_for_pane` | `nil`; optional pane filter, may receive `nil` |
| `time_format` | `%a %b %e %H:%M` |
