# wezterm-git-status-bridge

Bridge focused Herdr pane Git status into WezTerm right-status rendering.

The binary updates the cache files consumed by WezTerm:

- `herdr-git-info`: latest focused Herdr pane status
- `herdr-git-info-by-pane/<pane-id>`: latest status per Herdr pane

Payloads use a tab-separated `herdrgit1` line so existing WezTerm Lua can keep
rendering synchronously without spawning `git`.

## Usage

Install the binary somewhere in `PATH`, then install the Herdr plugin from
`contrib/herdr-plugin`.

```sh
wezterm-git-status-bridge update
```

The update command reads pane context in this order:

1. `--pane-id` and `--cwd`
2. `--event-json`
3. `HERDR_PLUGIN_EVENT_JSON`
4. `herdr pane list`

Set `WEZTERM_GIT_STATUS_BRIDGE_BIN` when the Herdr plugin should use a binary
outside `PATH`. Set `HERDR_BIN_PATH` when `herdr` is outside `PATH`.

## Development

```sh
nix develop
cargo fmt --all -- --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test --all-targets --all-features
cargo audit
cargo machete
```
