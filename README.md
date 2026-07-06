# wezterm-git-status-bridge

<img width="507" height="173" alt="image" src="https://github.com/user-attachments/assets/757f2ad4-c2fc-4ec1-a33c-35fccf06c1e0" />

Show Git repository status in WezTerm's right status without running `git` from WezTerm's render path.

The bridge writes Git status to a cache file, and the Lua module renders from that cache. It shows the repository, branch or detached commit, dirty state, linked worktree state, and rebase or cherry-pick state.

## Requirements

- WezTerm
- `git`
- `wezterm-git-status-bridge`

Herdr is optional. The bundled Herdr plugin keeps the cache updated from the focused pane, but any hook can call the binary with a pane id and working directory.

## Setup

1. Install the binary.

   Download a release archive, extract it, and put the included binary in `PATH`.

2. Copy the Lua module into your WezTerm configuration directory.

   Use the included `contrib/wezterm/right-status.lua`, then load it from `wezterm.lua`:

   ```lua
   local git_status = require("right-status")

   git_status.setup()
   ```

   If you already manage `update-right-status`, compose the segments yourself:

   ```lua
   local wezterm = require("wezterm")
   local git_status = require("right-status")

   wezterm.on("update-right-status", function(window, pane)
     window:set_right_status(wezterm.format(git_status.segments(window, pane)))
   end)
   ```

3. Keep the cache updated.

   With Herdr, install the included `contrib/herdr-plugin` plugin and reload Herdr. If the binary is not in `PATH`, set `WEZTERM_GIT_STATUS_BRIDGE_BIN`.

   Without Herdr, call the binary from a shell hook, editor hook, or terminal automation:

   ```sh
   wezterm-git-status-bridge update --pane-id <stable-pane-id> --cwd <working-directory>
   ```

4. Reload WezTerm.

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
  max_age_seconds = 300,
  show_time = true,
  time_format = "%a %b %e %H:%M",
})
```

Common options:

| Option | Default |
| --- | --- |
| `max_age_seconds` | `300`; set `false` to disable TTL hiding |
| `separator` | Powerline separator with spacing |
| `show_time` | `true` |
| `colors` | Tokyo Night-inspired muted dark palette |
| `mode_styles` | `nil`; key-table labels to prepend before Git status |
| `status_bg` | `#1f1f28`; applied after a mode label, set `false` to disable |
| `show_git_for_pane` | `nil`; optional pane filter, may receive `nil` |
| `time_format` | `%a %b %e %H:%M` |
