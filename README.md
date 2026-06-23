# Codex Status Bar

A tiny macOS menu bar app for Codex. It shows when Codex is thinking, running a tool, waiting for your input, or waiting for permission, and it can check remaining Codex quota from the menu.

This project is adapted from [`m1ckc3s/claude-status-bar`](https://github.com/m1ckc3s/claude-status-bar). The app architecture is the same: a Swift menu bar app polls a local state file written by lightweight Node hook scripts.

## What It Shows

- **Thinking / working**: animated Codex menu bar icon with optional status text and elapsed timer.
- **Running a tool**: short labels such as `Editing`, `Reading`, `Running command`, or `Using MCP`.
- **Needs input**: paused blue dot when a turn ends with a user-action prompt, including Plan Mode proposed plans.
- **Awaiting permission**: paused yellow dot when Codex emits a `PermissionRequest` hook.
- **Idle / done**: resting icon only, with no menu bar text.
- **Codex workflow menu**: left-click shows Open Codex, active/recent threads, New Thread, and quota refresh/details.
- **Status bar settings**: right-click shows appearance and animation controls.

## Requirements

- macOS 12+
- Codex CLI / Codex app
- Node.js, used by the hook and quota scripts
- Xcode Command Line Tools for building from source

## Install

Build the app:

```bash
./build.sh
```

Then open `build.noindex/CodexStatusBar.app` once. The `.noindex` build folder keeps the local build artifact out of Spotlight-style app pickers. On first launch it installs hooks into:

```text
$CODEX_HOME/hooks.json
```

If `CODEX_HOME` is unset, it uses `~/.codex`. The installer copies its hook scripts into:

```text
$CODEX_HOME/statusbar/
```

Start a new Codex session after installing so Codex loads the hooks. Non-managed hooks may need to be reviewed and trusted from Codex's `/hooks` UI.

## Usage

Left-click the menu bar icon for Codex actions: open Codex, jump to active or recent threads, start a new thread, and refresh quota. The quota heading uses the active Codex account email when available.

Hover the menu bar icon to see the active thread title and project name when the
thread is not projectless.

Right-click the menu bar icon for Codex Status Bar settings:

- **Color** for System or Codex Green
- **Animation Speed**
- **Show Status Text**
- **Show Elapsed Time**
- **Show Paused Elapsed Time** for permission/input pauses

## Quota Sources

The helper tries, in order:

1. `codex app-server --stdio` with `account/rateLimits/read`
2. `$CODEX_HOME/multi-auth/quota-cache.json`
3. A fallback message telling you to open Codex and run `/status`

Quota is fetched only when clicked; the app does not continuously poll quota data.

## How It Works

Codex hooks write the current state to:

```text
$CODEX_HOME/statusbar/state.json
```

The menu bar app polls that file and renders the current state. Active sessions are tracked as recent files under:

```text
$CODEX_HOME/statusbar/sessions.d/
```

Because Codex does not currently provide a documented `SessionEnd` hook, stale session files are expired by the app. If Codex is running, stale thinking/tool records are ignored after a safety window so an old thread cannot pin the menu bar to the wrong status or elapsed time. If Codex is not running, only very recent hook activity keeps the icon alive briefly.

Codex does not currently provide a dedicated `NeedsInput` hook. The status bar infers that state from the `Stop` hook's `last_assistant_message`, including Plan Mode `<proposed_plan>` output and direct user questions.

## Uninstall

Run:

```bash
node "/Applications/CodexStatusBar.app/Contents/Resources/uninstall.js"
```

or, from a local build:

```bash
node "build.noindex/CodexStatusBar.app/Contents/Resources/uninstall.js"
```

Then remove the app. The uninstaller removes only hook commands pointing inside `$CODEX_HOME/statusbar/`.

## Build From Source

```bash
./build.sh
./build.sh --dmg
```

`./build.sh` creates `build.noindex/CodexStatusBar.app`. `--dmg` creates `build.noindex/CodexStatusBar.dmg`.

Signing is optional for local builds. To produce a Developer ID build, set:

```bash
TEAM_ID=YOURTEAMID NOTARY_PROFILE=codex-statusbar ./build.sh --dmg
```

Use `SKIP_NOTARIZE=1` for a signed but non-notarized layout test.

## License

MIT. See [LICENSE](LICENSE).

Upstream attribution: this project is adapted from Mick Cesanek's `claude-status-bar`, also MIT licensed.
