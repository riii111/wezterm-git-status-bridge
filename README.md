# wezterm-git-status-bridge

Bridge focused Herdr pane Git status into WezTerm right-status rendering.

## Components

- Rust CLI: updates the cache files consumed by WezTerm.
- Herdr plugin: runs the CLI on pane and workspace events.
- WezTerm Lua module: reads the cache and renders the right status.

## Requirements

- `git`
- Herdr 0.7.0 or newer
- WezTerm
- macOS for the bundled Herdr plugin

## Usage

Install the binary somewhere in `PATH`, then install the Herdr plugin from `contrib/herdr-plugin`.

```sh
wezterm-git-status-bridge update
nix run github:riii111/wezterm-git-status-bridge -- update
```

Install `contrib/wezterm/right-status.lua` in your WezTerm configuration directory and load it from `wezterm.lua`:

```lua
local git_status = require("right-status")
git_status.setup()
```

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
4. `herdr pane list`

Set `WEZTERM_GIT_STATUS_BRIDGE_BIN` when the Herdr plugin should use a binary outside `PATH`. Set `HERDR_BIN_PATH` when `herdr` is outside `PATH`.

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
