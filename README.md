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

1. Install the binary.

   Download a release archive, extract it, and put the included binary in `PATH`.

2. Copy the Lua module into your WezTerm configuration directory.

   Use the included `contrib/wezterm/right-status.lua`, then load it from `wezterm.lua`:

   ```lua
   local git_status = require("right-status")

   git_status.setup()
   ```

   If you already manage `update-right-status`, refresh the cache before composing the segments:

   ```lua
   local wezterm = require("wezterm")
   local git_status = require("right-status")

   wezterm.on("update-right-status", function(window, pane)
     git_status.refresh(pane)
     window:set_right_status(wezterm.format(git_status.segments(window, pane)))
   end)
   ```

3. Reload WezTerm.

## Notes

For a manual one-off update:

```sh
wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"
```

For Nix:

```sh
nix run github:riii111/wezterm-git-status-bridge -- update --pane-id manual --cwd "$PWD"
```

Lua options:

```lua
git_status.setup({
  auto_update = true,
  max_age_seconds = 300,
  show_time = true,
  time_format = "%a %b %e %H:%M",
})
```

Herdr users can install the included `contrib/herdr-plugin` plugin and disable WezTerm-side updates:

```lua
git_status.setup({
  auto_update = false,
})
```

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
