#!/usr/bin/env node
// Fetch Codex quota on demand. Primary source is the local Codex app-server
// method account/rateLimits/read; fallback is this Mac's multi-auth cache.

const fs = require("fs");
const os = require("os");
const path = require("path");
const cp = require("child_process");

const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
const cachePath = path.join(codexHome, "multi-auth", "quota-cache.json");
const registryPath = path.join(codexHome, "accounts", "registry.json");
const authPath = path.join(codexHome, "auth.json");
const CACHE_MAX_AGE_MS = 10 * 60 * 1000;

function percent(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  return Math.max(0, Math.min(100, Math.round(value)));
}

function normalizeWindow(win) {
  if (!win || typeof win !== "object") return null;
  const usedPercent = percent(win.usedPercent ?? win.used_percent);
  if (usedPercent == null) return null;
  const resetsAt = win.resetsAt ?? win.resetAtMs ?? win.reset_at ?? null;
  const seconds = win.limit_window_seconds;
  const windowDurationMins = win.windowDurationMins ?? win.windowMinutes ?? (typeof seconds === "number" ? seconds / 60 : null);
  return {
    usedPercent,
    remainingPercent: Math.max(0, 100 - usedPercent),
    resetsAt,
    windowDurationMins,
  };
}

function normalizeSnapshot(snapshot, source) {
  if (!snapshot || typeof snapshot !== "object") return null;
  if (snapshot.rate_limit) return normalizeUsageStatus(snapshot, source);
  return {
    source,
    accountEmail: activeAccountEmail(),
    planType: snapshot.planType || null,
    limitId: snapshot.limitId || null,
    limitName: snapshot.limitName || null,
    primary: normalizeWindow(snapshot.primary),
    secondary: normalizeWindow(snapshot.secondary),
    credits: snapshot.credits || null,
    individualLimit: snapshot.individualLimit || null,
    rateLimitReachedType: snapshot.rateLimitReachedType || null,
    updatedAt: snapshot.updatedAt || Date.now(),
  };
}

function normalizeUsageStatus(status, source) {
  const rateLimit = status.rate_limit;
  if (!rateLimit || typeof rateLimit !== "object") return null;
  return {
    source,
    accountEmail: activeAccountEmail(),
    planType: status.plan_type || null,
    limitId: null,
    limitName: status.rate_limit_name || null,
    primary: normalizeWindow(rateLimit.primary_window),
    secondary: normalizeWindow(rateLimit.secondary_window),
    credits: status.credits || null,
    individualLimit: status.spend_control?.individual_limit || null,
    rateLimitReachedType: status.rate_limit_reached_type || null,
    updatedAt: Date.now(),
  };
}

function activeAccountEmail() {
  try {
    const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
    const activeKey = registry.active_account_key;
    const accounts = Array.isArray(registry.accounts) ? registry.accounts : [];
    const account = accounts.find((entry) => entry && entry.account_key === activeKey);
    if (account && typeof account.email === "string" && account.email.trim()) {
      return account.email.trim();
    }
  } catch {}

  try {
    const auth = JSON.parse(fs.readFileSync(authPath, "utf8"));
    const accountId = auth?.tokens?.account_id;
    if (!accountId) return null;
    const registry = JSON.parse(fs.readFileSync(registryPath, "utf8"));
    const accounts = Array.isArray(registry.accounts) ? registry.accounts : [];
    const account = accounts.find((entry) => entry && entry.chatgpt_account_id === accountId);
    if (account && typeof account.email === "string" && account.email.trim()) {
      return account.email.trim();
    }
  } catch {}

  return null;
}

function chooseRateLimit(payload) {
  if (payload && payload.rate_limit) return payload;
  const byId = payload && payload.rateLimitsByLimitId;
  if (byId && typeof byId === "object") {
    if (byId.codex) return byId.codex;
    const entries = Object.entries(byId);
    const withCodexName = entries.find(([, value]) =>
      String(value && (value.limitName || value.limitId || "")).toLowerCase().includes("codex")
    );
    if (withCodexName) return withCodexName[1];
    if (entries.length > 0) return entries[0][1];
  }
  return payload && payload.rateLimits;
}

function callAppServer() {
  return new Promise((resolve, reject) => {
    const codexBin = process.env.CODEX_CLI_PATH || "codex";
    const child = cp.spawn(codexBin, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
      env: { ...process.env, CODEX_HOME: codexHome },
    });

    let stdout = "";
    let stderr = "";
    let settled = false;
    let sentQuotaRequest = false;

    const timer = setTimeout(() => {
      fail(new Error("app-server quota request timed out"));
    }, 8000);

    function cleanup() {
      clearTimeout(timer);
      child.stdout?.removeAllListeners();
      child.stderr?.removeAllListeners();
      child.removeAllListeners();
      if (!child.killed) child.kill();
    }

    function done(value) {
      if (settled) return;
      settled = true;
      cleanup();
      resolve(value);
    }

    function fail(error) {
      if (settled) return;
      settled = true;
      cleanup();
      reject(error);
    }

    function send(message) {
      child.stdin.write(JSON.stringify(message) + "\n");
    }

    function sendQuotaRequest() {
      if (sentQuotaRequest) return;
      sentQuotaRequest = true;
      send({ id: 1, method: "account/rateLimits/read" });
    }

    child.on("error", fail);
    child.on("exit", (code, signal) => {
      if (!settled && code !== 0) {
        fail(new Error((stderr || `codex app-server exited ${code ?? signal}`).trim()));
      }
    });

    child.stderr.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.stdout.on("data", (chunk) => {
      stdout += chunk.toString();
      const lines = stdout.split(/\r?\n/);
      stdout = lines.pop() || "";

      for (const line of lines) {
        if (!line.trim()) continue;
        let msg;
        try { msg = JSON.parse(line); } catch { continue; }

        if (msg.id === 0 && msg.result) {
          send({ method: "initialized" });
          setTimeout(sendQuotaRequest, 100);
          continue;
        }
        if (msg.id === 1 && msg.result) {
          done(msg.result);
          return;
        }
        if (msg.id === 1 && msg.error) {
          fail(new Error(msg.error.message || "app-server quota request failed"));
          return;
        }
      }
    });

    send({
      id: 0,
      method: "initialize",
      params: {
        clientInfo: { name: "codex-status-bar", version: "0.1.0" },
        capabilities: {},
      },
    });
  });
}

function readCache() {
  const data = JSON.parse(fs.readFileSync(cachePath, "utf8"));
  const accounts = Object.values(data.byAccountId || {});
  const ok = accounts
    .filter((entry) => entry && entry.status === 200 && Date.now() - (entry.updatedAt || 0) <= CACHE_MAX_AGE_MS)
    .sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0));
  if (ok.length === 0) throw new Error("quota cache has no fresh successful entries");
  return ok[0];
}

async function main() {
  const errors = [];
  try {
    const payload = await callAppServer();
    const normalized = normalizeSnapshot(chooseRateLimit(payload), "app-server");
    if (normalized) {
      process.stdout.write(JSON.stringify(normalized) + "\n");
      return;
    }
    errors.push("app-server returned no rate limits");
  } catch (error) {
    errors.push(`app-server: ${error.message}`);
  }

  try {
    const normalized = normalizeSnapshot(readCache(), "multi-auth-cache");
    if (normalized) {
      process.stdout.write(JSON.stringify(normalized) + "\n");
      return;
    }
    errors.push("cache returned no rate limits");
  } catch (error) {
    errors.push(`cache: ${error.message}`);
  }

  process.stdout.write(JSON.stringify({
    source: "unavailable",
    error: errors.join("; "),
    message: "Live quota unavailable",
    details: "Open Codex Usage remaining for current limits.",
  }) + "\n");
}

main().catch((error) => {
  process.stdout.write(JSON.stringify({
    source: "unavailable",
    error: error.message,
    message: "Live quota unavailable",
    details: "Open Codex Usage remaining for current limits.",
  }) + "\n");
});
