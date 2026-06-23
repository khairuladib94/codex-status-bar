#!/usr/bin/env node
// SessionStart lifecycle for Codex. Launches the menu bar app and records the
// current thread/session as active under $CODEX_HOME/statusbar/sessions.d/.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const BUNDLE_ID = "com.local.codexstatusbar";
const EXEC = "CodexStatusBar";
const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const dir = path.join(codexHome, "statusbar");
const sessDir = path.join(dir, "sessions.d");

fs.mkdirSync(sessDir, { recursive: true });

const running = () => {
  try { cp.execFileSync("pgrep", ["-x", EXEC], { stdio: "ignore" }); return true; }
  catch { return false; }
};
const safeId = (s) => String(s || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64) || "unknown";

let input = "";
let done = false;
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

function run() {
  if (done) return;
  done = true;

  let id = "";
  try {
    const p = JSON.parse(input || "{}");
    id = p.session_id || p.thread_id || p.threadId || "";
  } catch {}
  id = safeId(id);

  if (!running()) {
    try {
      for (const file of fs.readdirSync(sessDir)) fs.rmSync(path.join(sessDir, file), { force: true });
    } catch {}
  }

  try { fs.writeFileSync(path.join(sessDir, id), ""); } catch {}
  cp.spawn("open", ["-g", "-b", BUNDLE_ID], { stdio: "ignore", detached: true }).unref();
  process.exit(0);
}
