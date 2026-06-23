# Changelog

## 0.1.0

- Initial Codex Status Bar implementation adapted from `m1ckc3s/claude-status-bar`.
- Renamed the app, bundle, hooks, state paths, and build artifacts for Codex.
- Added Codex hook support for `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, and `Stop`.
- Added on-demand quota checking through `codex app-server proxy` with a `multi-auth` cache fallback.
- Added left-click quota refresh and a right-click Codex-style active/recent thread menu.
- Added local Codex-style animated icon, optional status text, optional elapsed timer, and active account email in quota results.
