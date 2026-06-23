#!/usr/bin/env node
const assert = require("assert");
const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const repo = path.resolve(__dirname, "..");
const update = path.join(repo, "hooks", "update.js");

function runHook(home, event, payload) {
  cp.execFileSync(process.execPath, [update, event], {
    input: JSON.stringify(payload),
    env: { ...process.env, CODEX_HOME: home },
  });
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function makeHome() {
  return fs.mkdtempSync(path.join(os.tmpdir(), "codex-statusbar-test-"));
}

function payload(extra = {}) {
  return {
    session_id: "session-1",
    cwd: repo,
    transcript_path: path.join(repo, "transcript.jsonl"),
    ...extra,
  };
}

function statePath(home) {
  return path.join(home, "statusbar", "state.json");
}

function sessionPath(home) {
  return path.join(home, "statusbar", "sessions.d", "session-1");
}

{
  const home = makeHome();
  runHook(home, "prompt", payload());
  assert.strictEqual(readJson(statePath(home)).state, "thinking");
}

{
  const home = makeHome();
  runHook(home, "pre", payload({ tool_name: "Bash" }));
  const state = readJson(statePath(home));
  assert.strictEqual(state.state, "tool");
  assert.strictEqual(state.label, "Running command");
}

{
  const home = makeHome();
  runHook(home, "permission", payload({ tool_name: "Bash" }));
  assert.strictEqual(readJson(statePath(home)).state, "permission");
}

{
  const home = makeHome();
  runHook(home, "prompt", payload());
  runHook(home, "stop", payload({ last_assistant_message: "Done." }));
  assert.strictEqual(readJson(statePath(home)).state, "done");
  assert.strictEqual(fs.existsSync(sessionPath(home)), false);
}

{
  const home = makeHome();
  runHook(home, "prompt", payload());
  const startedAt = readJson(statePath(home)).startedAt;
  runHook(home, "stop", payload({ last_assistant_message: "<proposed_plan>\nPlan\n</proposed_plan>" }));
  const state = readJson(statePath(home));
  assert.strictEqual(state.state, "waiting");
  assert.strictEqual(state.previousStartedAt, startedAt);
  assert.strictEqual(readJson(sessionPath(home)).state, "waiting");
}

{
  const home = makeHome();
  runHook(home, "prompt", payload());
  runHook(home, "stop", payload({ last_assistant_message: "Which option should I use?" }));
  assert.strictEqual(readJson(statePath(home)).state, "waiting");
  assert.strictEqual(readJson(sessionPath(home)).state, "waiting");
}

{
  const home = makeHome();
  runHook(home, "prompt", payload());
  runHook(home, "stop", payload({ last_assistant_message: "The report is ready. Want me to trace it?" }));
  assert.strictEqual(readJson(statePath(home)).state, "done");
  assert.strictEqual(fs.existsSync(sessionPath(home)), false);
}

{
  const home = makeHome();
  const transcript = path.join(home, "transcript.jsonl");
  fs.writeFileSync(transcript, [
    JSON.stringify({ payload: { type: "message", role: "user", content: "Test" } }),
    JSON.stringify({ payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Which option should I use?" }] } }),
    "",
  ].join("\n"));
  runHook(home, "prompt", payload({ transcript_path: transcript }));
  runHook(home, "stop", payload({ transcript_path: transcript }));
  assert.strictEqual(readJson(statePath(home)).state, "waiting");
  assert.strictEqual(readJson(sessionPath(home)).state, "waiting");
}

console.log("update hook tests passed");
