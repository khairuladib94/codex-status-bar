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

function compactText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function permissionLabel(payload, tool) {
  const description = compactText(payload.tool_input && payload.tool_input.description);
  if (description) return description.length > 64 ? `${description.slice(0, 61)}...` : description;
  if (tool) return `Approve ${TOOL_LABELS[tool] || tool}`;
  return "Awaiting permission";
}

function stripCodeBlocks(text) {
  return String(text || "").replace(/```[\s\S]*?```/g, "");
}

function needsUserInput(message) {
  const text = stripCodeBlocks(message).trim();
  if (!text) return false;
  const lower = text.toLowerCase();

  if (/<\s*proposed_plan\b/i.test(text) || /<\s*\/\s*proposed_plan\s*>/i.test(text)) {
    return true;
  }

  if (/\b(needs input|awaiting (your )?(input|response|reply)|please (confirm|choose|select|reply|provide|send)|choose one|pick one)\b/.test(lower)) {
    return true;
  }

  return /\b(which option|which path|which one|what should i|where should i|when should i|who should i|how should i|do you want me to proceed|should i proceed|should i continue|should i use|can you provide|can you send)\b[^?]{0,160}\?/.test(lower);
}

function tailText(file, bytes = 256 * 1024) {
  try {
    const stat = fs.statSync(file);
    const fd = fs.openSync(file, "r");
    try {
      const size = Math.min(bytes, stat.size);
      const buffer = Buffer.alloc(size);
      fs.readSync(fd, buffer, 0, size, stat.size - size);
      return buffer.toString("utf8");
    } finally {
      fs.closeSync(fd);
    }
  } catch {
    return "";
  }
}

function textFromContent(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => {
      if (typeof part === "string") return part;
      return part && (part.text || part.output_text || part.content || "");
    })
    .filter(Boolean)
    .join("\n");
}

function assistantMessageFromRecord(record) {
  const payload = record && record.payload;
  if (!payload) return "";

  if (payload.type === "agent_message" && payload.message) return payload.message;
  if (payload.type === "message" && payload.role === "assistant") return textFromContent(payload.content);
  if (payload.role === "assistant") return textFromContent(payload.content || payload.message);

  return "";
}

function lastAssistantMessageFromTranscript(file) {
  const text = tailText(file);
  if (!text) return "";

  const lines = text.split(/\r?\n/).filter(Boolean);
  for (let i = lines.length - 1; i >= 0; i--) {
    try {
      const message = assistantMessageFromRecord(JSON.parse(lines[i]));
      if (message.trim()) return message;
    } catch {}
  }
  return "";
}

function sessionPathFor(payload) {
  const id = safeId(payload.session_id || payload.thread_id || payload.threadId);
  if (!id) return "";
  try {
    const sessDir = path.join(dir, "sessions.d");
    fs.mkdirSync(sessDir, { recursive: true });
    return path.join(sessDir, id);
  } catch {
    return "";
  }
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

  const sessionPath = sessionPathFor(p);
  let prev = {};
  try {
    if (sessionPath) prev = JSON.parse(fs.readFileSync(sessionPath, "utf8"));
  } catch {}
  if (!prev || Object.keys(prev).length === 0) {
    try {
      const globalPrev = JSON.parse(fs.readFileSync(statePath, "utf8"));
      const id = p.session_id || p.thread_id || p.threadId || "";
      if (!id || globalPrev.sessionId === id) prev = globalPrev;
    } catch {}
  }

  const project = p.cwd ? path.basename(p.cwd) : prev.project || "";
  const ts = Math.floor(Date.now() / 1000);
  const tool = toolName(p);
  let state = "idle";
  let label = "";
  let startedAt = prev.startedAt || 0;
  let previousStartedAt = prev.previousStartedAt || prev.startedAt || 0;

  switch (event) {
    case "prompt":
      state = "thinking";
      label = "Thinking...";
      startedAt = ts;
      previousStartedAt = startedAt;
      break;
    case "pre":
      state = "tool";
      label = TOOL_LABELS[tool] || (tool.startsWith("mcp__") ? "Using MCP" : "Using tool");
      if (!startedAt) startedAt = ts;
      previousStartedAt = startedAt;
      break;
    case "post":
      state = "thinking";
      label = "Thinking...";
      if (!startedAt) startedAt = ts;
      previousStartedAt = startedAt;
      break;
    case "permission":
      state = "permission";
      label = permissionLabel(p, tool);
      startedAt = 0;
      break;
    case "stop":
      const lastAssistantMessage = p.last_assistant_message
        || p.lastAssistantMessage
        || lastAssistantMessageFromTranscript(p.transcript_path || p.transcript || prev.transcript);
      if (needsUserInput(lastAssistantMessage)) {
        state = "waiting";
        label = "Needs input";
      } else {
        state = "done";
        label = "Done";
      }
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
    previousStartedAt,
    ts,
  };

  try {
    fs.mkdirSync(dir, { recursive: true });
    if (sessionPath) {
      if (event === "stop" && state !== "waiting") {
        fs.rmSync(sessionPath, { force: true });
      } else {
        const tmpSession = `${sessionPath}.${process.pid}.tmp`;
        fs.writeFileSync(tmpSession, JSON.stringify(out));
        fs.renameSync(tmpSession, sessionPath);
      }
    }
    const tmp = `${statePath}.${process.pid}.tmp`;
    fs.writeFileSync(tmp, JSON.stringify(out));
    fs.renameSync(tmp, statePath);
  } catch {}

  process.exit(0);
}
