# wezterm-git-status-bridge

Bridge focused Herdr pane Git status into WezTerm right-status rendering.

## Components

- Rust CLI: updates the cache files consumed by WezTerm.
- Herdr plugin: runs the CLI on pane and workspace events.
- WezTerm Lua module: reads the cache and renders the right status.

## Requirements

- `git`
- [Herdr](https://herdr.dev) 0.7.0 or newer
- WezTerm with reasonably recent bundled Nerd Font symbols
- macOS for the bundled Herdr plugin

## Usage

Install the binary somewhere in `PATH`, then install the Herdr plugin from `contrib/herdr-plugin`.

```sh
wezterm-git-status-bridge update --pane-id manual --cwd "$PWD"
nix run github:riii111/wezterm-git-status-bridge -- update --pane-id manual --cwd "$PWD"
```

Install `contrib/wezterm/right-status.lua` in your WezTerm configuration directory and load it from `wezterm.lua`:

```lua
local git_status = require("right-status")
git_status.setup()
```

`setup()` registers `update-right-status`, `window-focus-changed`, `window-config-reloaded`, and a custom `render-right-status` event. Emit `render-right-status` from your own key bindings when you need an immediate redraw.

Common Lua options:

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

For custom composition, use `git_segments(options)`, `mode_segments(window, options)`, or `segments(window, pane, options)` and pass the result to `wezterm.format`.

The binary writes these cache files:

- `herdr-git-info`: latest focused Herdr pane status
- `herdr-git-info-by-pane/<pane-id>`: latest status per Herdr pane

Payloads use a tab-separated `herdrgit1` line so WezTerm can render synchronously without spawning `git`.

Flags are encoded as `D` for detached HEAD, `d` for dirty, `w` for worktree, `R` for rebase, and `C` for cherry-pick.

The status is a snapshot from the latest Herdr pane event. It does not update while focus stays on the same pane unless another Herdr event runs the bridge.

The update command resolves pane context in this order:

1. `--pane-id` and `--cwd`
2. `--event-json`
3. `HERDR_PLUGIN_EVENT_JSON`

Set `WEZTERM_GIT_STATUS_BRIDGE_BIN` when the Herdr plugin should use a binary outside `PATH`.
The Herdr plugin uses `HERDR_PLUGIN_EVENT_JSON` when available and falls back to `herdr pane list`.

## Development

```sh
nix develop
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-targets --all-features
cargo build --release
lua tests/right-status.lua "$(mktemp -d)"
cargo audit
cargo machete
```
