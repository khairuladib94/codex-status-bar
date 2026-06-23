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
  const request = JSON.stringify({ id: 1, method: "account/rateLimits/read", params: null }) + "\n";
  const result = cp.spawnSync("codex", ["app-server", "proxy"], {
    input: request,
    encoding: "utf8",
    timeout: 6000,
    env: { ...process.env, CODEX_HOME: codexHome },
  });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error((result.stderr || `codex app-server proxy exited ${result.status}`).trim());

  const lines = String(result.stdout || "").trim().split(/\r?\n/).filter(Boolean);
  for (const line of lines) {
    let msg;
    try { msg = JSON.parse(line); } catch { continue; }
    if (msg.id === 1 && msg.result) return msg.result;
    if (msg.id === 1 && msg.error) throw new Error(msg.error.message || "app-server quota request failed");
  }
  throw new Error("app-server quota response was empty");
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

function main() {
  const errors = [];
  try {
    const payload = callAppServer();
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

main();
