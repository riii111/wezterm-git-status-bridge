# wezterm-git-status-bridge

<img width="507" height="173" alt="image" src="https://github.com/user-attachments/assets/757f2ad4-c2fc-4ec1-a33c-35fccf06c1e0" />

Show Git repository status in WezTerm's right status without running `git` from WezTerm's render path.

The bridge writes Git status to a cache file, and the Lua module renders from that cache. It shows the repository, branch or detached commit, dirty state, linked worktree state, and rebase or cherry-pick state.

## Requirements

- WezTerm
- `git`
- `wezterm-git-status-bridge`

Herdr is optional. WezTerm can update the cache by itself; the Herdr plugin is only for users who want status from the focused pane inside Herdr.

## Setup

1. Install the binary in `PATH`.

   ```sh
   case "$(uname -m)" in
     arm64) target=aarch64-apple-darwin ;;
     x86_64) target=x86_64-apple-darwin ;;
     *) echo "unsupported arch" >&2; exit 1 ;;
   esac
   mkdir -p "$HOME/.local/bin"
   curl -L "https://github.com/riii111/wezterm-git-status-bridge/releases/latest/download/wezterm-git-status-bridge-$target.tar.gz" |
     tar xz -C /tmp
   install -m 0755 "/tmp/wezterm-git-status-bridge-$target/wezterm-git-status-bridge" "$HOME/.local/bin/"
   ```

2. Run the setup command, then reload WezTerm.

   ```sh
   wezterm-git-status-bridge setup
   ```

For Herdr:

```sh
wezterm-git-status-bridge setup --herdr
```

`setup` writes the Lua module and updates `wezterm.lua`. With `--herdr`, it also links the Herdr plugin and installs a zsh `chpwd` / `precmd` hook so branch switches and directory changes update the cache.

Rerunning `setup` refreshes the managed `binary_path` and Herdr defaults while preserving extra `git_status.setup({...})` options inside the setup block.

## Notes

The clock is shown by default because `show_time` defaults to `true`.

If you already manage `update-right-status`, keep your handler and call `git_status.refresh(pane)` before rendering `git_status.segments(window, pane)`.

For a Nix one-off update:

```sh
nix run github:riii111/wezterm-git-status-bridge -- update --pane-id manual --cwd "$PWD"
```

## Troubleshooting

- If Git status is shown but does not update, run `wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"` and reload WezTerm. If that works, the missing piece is the update trigger.
- If you set `auto_update = false`, something else must write the cache. Use the Herdr plugin, a shell hook, or both.
- Herdr plugin events do not cover every shell-level `cd` or `git switch` by themselves. Keep the shell hook unless another integration updates the cache.

Common options:

| Option | Default |
| --- | --- |
| `auto_update` | `true`; set `false` when another integration writes the cache |
| `binary_path` | `WEZTERM_GIT_STATUS_BRIDGE_BIN` or `wezterm-git-status-bridge` |
| `update_interval_seconds` | `2`; minimum seconds between background updates for the same pane and directory |
| `update_delay_seconds` | `0.2`; best-effort redraw delay after a background update request |
| `separator` | Powerline separator with spacing |
| `show_time` | `true` |
| `colors` | Tokyo Night-inspired muted dark palette |
| `mode_styles` | `nil`; key-table labels to prepend before Git status |
| `status_bg` | `#1f1f28`; applied after a mode label, set `false` to disable |
| `show_git_for_pane` | `nil`; optional pane filter, may receive `nil` |
| `time_format` | `%a %b %e %H:%M` |
