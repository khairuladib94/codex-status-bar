#!/usr/bin/env node
// Installs Codex status-bar hooks into $CODEX_HOME/hooks.json. Existing hooks
// are preserved; commands pointing inside $CODEX_HOME/statusbar are replaced.

const fs = require("fs");
const os = require("os");
const path = require("path");

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const sbDir = path.join(codexHome, "statusbar");
const marker = sbDir;
const updateDest = path.join(sbDir, "update.js");
const lifecycleDest = path.join(sbDir, "lifecycle.js");
const appPathDest = path.join(sbDir, "app-path");
const hooksPath = path.join(codexHome, "hooks.json");
const node = process.execPath;

function validAppPath(value) {
  return Boolean(
    value &&
    value.endsWith(".app") &&
    fs.existsSync(path.join(value, "Contents", "MacOS", "CodexStatusBar"))
  );
}

function detectAppPath() {
  const bundled = path.resolve(__dirname, "..", "..");
  const candidates = [
    process.env.CODEX_STATUS_BAR_APP,
    validAppPath(bundled) ? bundled : null,
    "/Applications/CodexStatusBar.app",
    path.resolve(__dirname, "..", "build.noindex", "CodexStatusBar.app"),
    path.resolve(__dirname, "..", "build", "CodexStatusBar.app"),
  ];
  return candidates.find(validAppPath) || null;
}

fs.mkdirSync(sbDir, { recursive: true });
fs.copyFileSync(path.join(__dirname, "update.js"), updateDest);
fs.copyFileSync(path.join(__dirname, "lifecycle.js"), lifecycleDest);

const appPath = detectAppPath();
if (appPath) fs.writeFileSync(appPathDest, appPath + "\n");

const quote = (value) => JSON.stringify(value);
const cmd = (evt) => `${quote(node)} ${quote(updateDest)} ${evt}`;
const life = () => `${quote(node)} ${quote(lifecycleDest)} start`;

let config = {};
if (fs.existsSync(hooksPath)) {
  config = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  const bak = hooksPath + ".bak-statusbar";
  if (!fs.existsSync(bak)) fs.copyFileSync(hooksPath, bak);
}
config.hooks = config.hooks || {};

const stripOurs = (arr) =>
  (arr || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(marker)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);

const addUnmatched = (evt, command) => {
  config.hooks[evt] = stripOurs(config.hooks[evt]);
  config.hooks[evt].push({ hooks: [{ type: "command", command }] });
};

const addMatched = (evt, command) => {
  config.hooks[evt] = stripOurs(config.hooks[evt]);
  config.hooks[evt].push({ matcher: "*", hooks: [{ type: "command", command }] });
};

addUnmatched("SessionStart", life());
addUnmatched("UserPromptSubmit", cmd("prompt"));
addMatched("PreToolUse", cmd("pre"));
addMatched("PostToolUse", cmd("post"));
addMatched("PermissionRequest", cmd("permission"));
addUnmatched("Stop", cmd("stop"));

fs.mkdirSync(codexHome, { recursive: true });
fs.writeFileSync(hooksPath, JSON.stringify(config, null, 2) + "\n");
console.log("Installed Codex status-bar hooks into", hooksPath);
console.log("Scripts:", updateDest, "and", lifecycleDest);
if (appPath) console.log("App:", appPath);
console.log("Backup (first run only):", hooksPath + ".bak-statusbar");
