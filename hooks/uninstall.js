#!/usr/bin/env node
// Removes only Codex Status Bar hooks from $CODEX_HOME/hooks.json.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const marker = path.join(codexHome, "statusbar");
const hooksPath = path.join(codexHome, "hooks.json");

try { cp.execFileSync("pkill", ["-x", "CodexStatusBar"], { stdio: "ignore" }); } catch {}

if (!fs.existsSync(hooksPath)) {
  console.log("No hooks.json; nothing to do.");
  process.exit(0);
}

const config = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
for (const evt of Object.keys(config.hooks || {})) {
  config.hooks[evt] = (config.hooks[evt] || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((h) => !(h.command || "").includes(marker)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);
  if (config.hooks[evt].length === 0) delete config.hooks[evt];
}

fs.writeFileSync(hooksPath, JSON.stringify(config, null, 2) + "\n");
console.log("Removed Codex Status Bar hooks from", hooksPath);
