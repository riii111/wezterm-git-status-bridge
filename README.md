# wezterm-git-status-bridge

<img width="507" height="173" alt="image" src="https://github.com/user-attachments/assets/757f2ad4-c2fc-4ec1-a33c-35fccf06c1e0" />

Show Git repository status at the right edge of WezTerm or Kitty without running `git` from a terminal render path.

The Rust bridge writes terminal-independent status payloads to cache files. Thin Lua and Python adapters render the repository, branch or detached commit, dirty state, linked worktree state, and rebase or cherry-pick state.

## Requirements

- WezTerm or Kitty
- `git`
- `wezterm-git-status-bridge`

Herdr is optional. The Herdr plugin is only for users who want status from the focused pane inside Herdr.

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

2. Run setup for the terminal, then reload its configuration.

   WezTerm remains the default for compatibility:

   ```sh
   wezterm-git-status-bridge setup
   ```

   For Kitty:

   ```sh
   wezterm-git-status-bridge setup --kitty
   ```

   To install both adapters together:

   ```sh
   wezterm-git-status-bridge setup --wezterm --kitty
   ```

For Herdr:

```sh
wezterm-git-status-bridge setup --herdr
# Kitty only
wezterm-git-status-bridge setup --kitty --herdr
```

WezTerm setup writes the Lua module and updates `wezterm.lua`. Kitty setup writes `tab_bar.py`, enables the custom tab bar, keeps it visible for one tab, and installs a zsh `chpwd` / `precmd` hook. `--herdr` also links the Herdr plugin.

Kitty redraws the tab bar on a timer, but only reads one-line cache files there. Git commands remain in the background shell hook. `KITTY_WINDOW_ID` keeps per-window writes separate while the cwd cache joins equivalent terminal contexts.

Herdr host status depends on the plugin-written focused cache. The shell hook keeps that focused pane's cwd cache fresh between focus changes.

Rerunning `setup` refreshes the managed `binary_path` and Herdr defaults while preserving extra `git_status.setup({...})` options inside the setup block.

## Notes

The clock is shown by default because `show_time` defaults to `true`.

For WezTerm, if you already manage `update-right-status`, keep your handler and call `git_status.refresh(pane)` before rendering `git_status.segments(window, pane)`.

For a Nix one-off update:

```sh
nix run github:riii111/wezterm-git-status-bridge -- update --pane-id manual --cwd "$PWD"
```

## Troubleshooting

- If Git status is shown but does not update, run `wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"` and reload the terminal configuration. If that works, the missing piece is the update trigger.
- Kitty requires the installed zsh hook (or another writer) because its adapter never launches Git from the tab bar.
- If you set `auto_update = false`, something else must write the cache. Use the Herdr plugin, a shell hook, or both.
- Herdr plugin events do not cover every shell-level `cd` or `git switch` by themselves. Keep the shell hook unless another integration updates the cache.

Common WezTerm options:

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
