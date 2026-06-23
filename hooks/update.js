#!/usr/bin/env node
// Invoked by Codex hooks. Reads the hook JSON payload on stdin, maps the event
// to a compact status, and atomically writes $CODEX_HOME/statusbar/state.json.
// Usage: node update.js <prompt|pre|post|permission|stop>

const fs = require("fs");
const os = require("os");
const path = require("path");

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const dir = path.join(codexHome, "statusbar");
const statePath = path.join(dir, "state.json");
const event = process.argv[2] || "";

const TOOL_LABELS = {
  Bash: "Running command",
  exec_command: "Running command",
  apply_patch: "Editing",
  Edit: "Editing",
  Write: "Writing",
  MultiEdit: "Editing",
  NotebookEdit: "Editing",
  Read: "Reading",
  Grep: "Searching",
  Glob: "Searching",
  WebFetch: "Browsing web",
  WebSearch: "Searching web",
  web_search: "Searching web",
  Task: "Delegating",
  TodoWrite: "Planning",
};

function safeId(value) {
  return String(value || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 64);
}

function toolName(payload) {
  return payload.tool_name || payload.tool || payload.toolName || payload.name || "";
}

function touchSession(payload) {
  const id = safeId(payload.session_id || payload.thread_id || payload.threadId);
  if (!id) return;
  try {
    const sessDir = path.join(dir, "sessions.d");
    fs.mkdirSync(sessDir, { recursive: true });
    const sessionPath = path.join(sessDir, id);
    if (event === "stop") fs.rmSync(sessionPath, { force: true });
    else fs.writeFileSync(sessionPath, "");
  } catch {}
}

let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

let done = false;
function run() {
  if (done) return;
  done = true;

  let p = {};
  try { p = JSON.parse(raw || "{}"); } catch {}

  if (process.env.CODEX_STATUSBAR_DEBUG === "1") {
    try {
      fs.mkdirSync(dir, { recursive: true });
      fs.appendFileSync(
        path.join(dir, "hooks.log"),
        `${new Date().toISOString()} [${event}] tool=${toolName(p) || "-"} keys=${Object.keys(p).join(",")}\n`
      );
    } catch {}
  }

  touchSession(p);

  let prev = {};
  try { prev = JSON.parse(fs.readFileSync(statePath, "utf8")); } catch {}

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  const tool = toolName(p);
  let state = "idle";
  let label = "";
  let startedAt = prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking";
      label = "Thinking...";
      startedAt = ts;
      break;
    case "pre":
      state = "tool";
      label = TOOL_LABELS[tool] || (tool.startsWith("mcp__") ? "Using MCP" : "Using tool");
      if (!startedAt) startedAt = ts;
      break;
    case "post":
      state = "thinking";
      label = "Thinking...";
      if (!startedAt) startedAt = ts;
      break;
    case "permission":
      state = "permission";
      label = "Awaiting permission";
      startedAt = 0;
      break;
    case "stop":
      state = "done";
      label = "Done";
      startedAt = 0;
      break;
    default:
      process.exit(0);
  }

  const out = {
    state,
    label,
    tool,
    project,
    sessionId: p.session_id || p.thread_id || p.threadId || "",
    transcript: p.transcript_path || p.transcript || prev.transcript || "",
    startedAt,
    ts,
  };

  try {
    fs.mkdirSync(dir, { recursive: true });
    const tmp = `${statePath}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}

  process.exit(0);
}
