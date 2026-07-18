#!/usr/bin/env node

import { createHash, randomUUID } from "node:crypto";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import {
  appendFile,
  mkdir,
  open,
  readFile,
  rename,
  stat,
  unlink,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  AUTO_CONSUME_LEAD_SECONDS,
  AUTO_CONSUME_PREPARE_SECONDS,
  discordTime,
  findQuotaDrops,
  formatKst,
  formatRemaining,
  getQuotaWindows,
  getWarningDecision,
  isCreditListComplete,
  listAvailableExpiringCredits,
  makeCreditKey,
  shouldAutoConsume,
} from "./lib/account-monitor-core.mjs";

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const SCHEDULER_SCRIPT = path.join(SCRIPT_DIR, "schedule-account-events.ps1");
const DATA_DIR =
  process.env.CODEX_ACCOUNT_MONITOR_DATA_DIR ||
  path.join(process.env.LOCALAPPDATA || os.homedir(), "CodexQuotaMonitor");
const STATE_FILE = path.join(DATA_DIR, "state.json");
const LOCK_FILE = path.join(DATA_DIR, "monitor.lock");
const DISABLED_FILE = path.join(DATA_DIR, "disabled");
const LOG_FILE = path.join(DATA_DIR, "monitor.log");
const REPOSITORY =
  process.env.CODEX_ACCOUNT_MONITOR_REPOSITORY ||
  "chae087810-stack/codex-reset-discord-monitor";
const ALERT_WORKFLOW = "account-alert.yml";
const ALERT_REF = process.env.CODEX_ACCOUNT_MONITOR_REF || "main";
const STATE_SCHEMA_VERSION = 1;
const MAX_LOG_BYTES = 1024 * 1024;

function firstExistingPath(candidates, fallback) {
  for (const candidate of candidates) {
    if (candidate && existsSync(candidate)) return candidate;
  }
  return fallback;
}

function resolveCodexExecutable() {
  if (process.env.CODEX_EXE) return process.env.CODEX_EXE;
  if (process.platform !== "win32") return "codex";

  const npmRoot = process.env.APPDATA
    ? path.join(process.env.APPDATA, "npm", "node_modules", "@openai", "codex")
    : null;
  return firstExistingPath(
    [
      npmRoot &&
        path.join(
          npmRoot,
          "node_modules",
          "@openai",
          "codex-win32-x64",
          "vendor",
          "x86_64-pc-windows-msvc",
          "bin",
          "codex.exe",
        ),
      npmRoot &&
        path.join(
          npmRoot,
          "node_modules",
          "@openai",
          "codex-win32-arm64",
          "vendor",
          "aarch64-pc-windows-msvc",
          "bin",
          "codex.exe",
        ),
      process.env.LOCALAPPDATA &&
        path.join(process.env.LOCALAPPDATA, "OpenAI", "Codex", "bin", "codex.exe"),
    ],
    "codex.exe",
  );
}

function resolveGhExecutable() {
  if (process.env.GH_EXE) return process.env.GH_EXE;
  if (process.platform !== "win32") return "gh";
  return firstExistingPath(
    [path.join(process.env.ProgramFiles || "C:\\Program Files", "GitHub CLI", "gh.exe")],
    "gh.exe",
  );
}

function nowUnix() {
  return Math.floor(Date.now() / 1000);
}

function isMonitorDisabled() {
  return existsSync(DISABLED_FILE);
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, Math.max(0, milliseconds)));
}

async function ensureDataDirectory() {
  await mkdir(DATA_DIR, { recursive: true });
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}

async function acquireMonitorLock(maxWaitMs = 6 * 60 * 1000) {
  await ensureDataDirectory();
  const deadline = Date.now() + maxWaitMs;

  while (true) {
    try {
      const handle = await open(LOCK_FILE, "wx");
      await handle.writeFile(
        `${JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })}\n`,
        "utf8",
      );
      let released = false;
      return async () => {
        if (released) return;
        released = true;
        await handle.close().catch(() => {});
        try {
          const current = JSON.parse(await readFile(LOCK_FILE, "utf8"));
          if (current?.pid === process.pid) await unlink(LOCK_FILE);
        } catch (error) {
          if (error?.code !== "ENOENT") await log("lock-release-failed", error.message);
        }
      };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;

      let stale = false;
      let hasValidOwner = false;
      try {
        const owner = JSON.parse(await readFile(LOCK_FILE, "utf8"));
        hasValidOwner = Number.isInteger(owner?.pid) && owner.pid > 0;
        stale = hasValidOwner && !isProcessAlive(owner.pid);
      } catch {
        // A just-created lock may not have its JSON written yet.
      }
      try {
        const info = await stat(LOCK_FILE);
        const ageMs = Date.now() - info.mtimeMs;
        if ((hasValidOwner && ageMs > 15 * 60 * 1000) || (!hasValidOwner && ageMs > 10_000)) {
          stale = true;
        }
      } catch (statError) {
        if (statError?.code === "ENOENT") continue;
      }

      if (stale) {
        await unlink(LOCK_FILE).catch(() => {});
        continue;
      }
      if (Date.now() >= deadline) {
        throw new Error("Another Codex account monitor instance is still running");
      }
      await sleep(500);
    }
  }
}

async function log(message, details = "") {
  await ensureDataDirectory();
  try {
    const info = await stat(LOG_FILE).catch(() => null);
    if (info?.size > MAX_LOG_BYTES) {
      await rename(LOG_FILE, `${LOG_FILE}.previous`).catch(() => {});
    }
    const suffix = details ? ` ${String(details).slice(0, 2000)}` : "";
    await appendFile(LOG_FILE, `${new Date().toISOString()} ${message}${suffix}\n`, "utf8");
  } catch {
    // Logging must never break expiry handling.
  }
}

function emptyState() {
  return {
    schemaVersion: STATE_SCHEMA_VERSION,
    credits: {},
    quotaWindows: [],
    outbox: [],
  };
}

async function loadState() {
  await ensureDataDirectory();
  try {
    const parsed = JSON.parse(await readFile(STATE_FILE, "utf8"));
    return {
      ...emptyState(),
      ...parsed,
      credits: parsed?.credits && typeof parsed.credits === "object" ? parsed.credits : {},
      quotaWindows: Array.isArray(parsed?.quotaWindows) ? parsed.quotaWindows : [],
      outbox: Array.isArray(parsed?.outbox) ? parsed.outbox : [],
    };
  } catch (error) {
    if (error?.code !== "ENOENT") await log("state-read-failed", error.message);
    return emptyState();
  }
}

async function saveState(state) {
  await ensureDataDirectory();
  state.schemaVersion = STATE_SCHEMA_VERSION;
  const temporary = `${STATE_FILE}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, "utf8");
  await rename(temporary, STATE_FILE);
}

function runHidden(executable, args, { timeoutMs = 30_000 } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      windowsHide: true,
      shell: false,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`${executable} timed out after ${timeoutMs} ms`));
    }, timeoutMs);

    child.stdout.on("data", (chunk) => {
      if (stdout.length < 16_000) stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk) => {
      if (stderr.length < 16_000) stderr += chunk.toString("utf8");
    });
    child.once("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`${executable} exited ${code}: ${stderr || stdout}`));
    });
  });
}

class CodexAppServerClient {
  constructor() {
    this.child = null;
    this.pending = new Map();
    this.nextId = 1;
    this.closed = false;
  }

  async start() {
    const executable = resolveCodexExecutable();
    this.child = spawn(executable, ["app-server", "--stdio"], {
      windowsHide: true,
      shell: false,
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child.once("error", (error) => this.failAll(error));
    this.child.once("exit", (code, signal) => {
      if (!this.closed) this.failAll(new Error(`Codex app-server exited (${code ?? signal})`));
    });
    this.child.stderr.on("data", (chunk) => {
      const text = chunk.toString("utf8").trim();
      if (text) void log("app-server-stderr", text);
    });
    this.child.stdin.on("error", (error) => this.failAll(error));

    const lines = createInterface({ input: this.child.stdout, crlfDelay: Infinity });
    lines.on("line", (line) => this.handleLine(line));

    await this.request("initialize", {
      clientInfo: {
        name: "codex_quota_monitor",
        title: "Codex Quota Monitor",
        version: "1.0.0",
      },
    });
    this.notify("initialized", {});
  }

  handleLine(line) {
    let message;
    try {
      message = JSON.parse(line);
    } catch {
      void log("app-server-invalid-json", line);
      return;
    }

    if (message.id !== undefined && this.pending.has(message.id)) {
      const pending = this.pending.get(message.id);
      this.pending.delete(message.id);
      clearTimeout(pending.timer);
      if (message.error) {
        pending.reject(new Error(message.error.message || JSON.stringify(message.error)));
      } else {
        pending.resolve(message.result);
      }
    }
  }

  request(method, params, timeoutMs = 20_000) {
    if (!this.child?.stdin?.writable) {
      return Promise.reject(new Error("Codex app-server is not writable"));
    }
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`${method} timed out after ${timeoutMs} ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.child.stdin.write(`${JSON.stringify({ method, id, params })}\n`, (error) => {
        if (!error || !this.pending.has(id)) return;
        const pending = this.pending.get(id);
        this.pending.delete(id);
        clearTimeout(pending.timer);
        pending.reject(error);
      });
    });
  }

  notify(method, params) {
    if (this.child?.stdin?.writable) {
      this.child.stdin.write(`${JSON.stringify({ method, params })}\n`);
    }
  }

  failAll(error) {
    for (const pending of this.pending.values()) {
      clearTimeout(pending.timer);
      pending.reject(error);
    }
    this.pending.clear();
  }

  async readRateLimits() {
    return this.request("account/rateLimits/read", null);
  }

  async consumeResetCredit(creditId, idempotencyKey) {
    return this.request("account/rateLimitResetCredit/consume", {
      creditId,
      idempotencyKey,
    });
  }

  close() {
    this.closed = true;
    this.failAll(new Error("Codex app-server closed"));
    if (this.child) {
      this.child.stdin.end();
      this.child.kill();
    }
  }
}

async function withAppServer(callback) {
  const client = new CodexAppServerClient();
  try {
    await client.start();
    return await callback(client);
  } finally {
    client.close();
  }
}

async function readRateLimits() {
  return withAppServer((client) => client.readRateLimits());
}

function taskKeyForCredit(credit) {
  return createHash("sha256").update(makeCreditKey(credit)).digest("hex").slice(0, 16);
}

function ensureCreditEntry(state, credit) {
  const rawKey = makeCreditKey(credit);
  const taskKey = taskKeyForCredit(credit);
  if (!state.credits[taskKey]) {
    state.credits[taskKey] = {
      creditKey: rawKey,
      taskKey,
      id: credit.id,
      expiresAt: Math.trunc(credit.expiresAt),
      title: credit.title || null,
      handledThresholds: [],
      scheduledFor: null,
      consume: {
        completed: false,
        outcome: null,
        attempts: 0,
        inFlightIdempotencyKey: null,
      },
    };
  }
  const entry = state.credits[taskKey];
  entry.title = credit.title || entry.title || null;
  return entry;
}

function quotaFields(windows) {
  return windows.map((window) => ({
    name: window.label,
    value: [
      `현재 사용량: **${window.usedPercent.toFixed(1).replace(/\.0$/, "")}%**`,
      window.resetsAt
        ? `예정 리셋:\n${discordTime(window.resetsAt)}`
        : "예정 리셋: 시각 정보 없음",
    ].join("\n"),
    inline: false,
  }));
}

function makeDiscordPayload({ title, description, color, fields = [], timestamp = new Date() }) {
  return {
    username: "Codex 실제 계정 알림",
    allowed_mentions: { parse: [] },
    embeds: [
      {
        title,
        description,
        color,
        fields: fields.slice(0, 25),
        timestamp: timestamp.toISOString(),
        footer: { text: "실제 Codex 계정 데이터 · Asia/Seoul" },
      },
    ],
  };
}

async function dispatchDiscord(payload) {
  const encoded = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");
  await runHidden(
    resolveGhExecutable(),
    [
      "workflow",
      "run",
      ALERT_WORKFLOW,
      "--repo",
      REPOSITORY,
      "--ref",
      ALERT_REF,
      "-f",
      `payload_b64=${encoded}`,
    ],
    { timeoutMs: 45_000 },
  );
}

async function sendOrQueue(state, payload) {
  try {
    await dispatchDiscord(payload);
    await log("discord-dispatched", payload.embeds?.[0]?.title || "alert");
    return true;
  } catch (error) {
    state.outbox.push({ payload, queuedAt: new Date().toISOString() });
    if (state.outbox.length > 20) state.outbox = state.outbox.slice(-20);
    await log("discord-queued", error.message);
    return false;
  }
}

async function flushOutbox(state) {
  if (!state.outbox.length) return;
  const remaining = [];
  for (const item of state.outbox) {
    try {
      await dispatchDiscord(item.payload);
    } catch (error) {
      remaining.push(item);
      await log("outbox-dispatch-failed", error.message);
      break;
    }
  }
  if (remaining.length) {
    const firstRemaining = state.outbox.indexOf(remaining[0]);
    state.outbox = state.outbox.slice(firstRemaining);
  } else {
    state.outbox = [];
  }
}

async function invokeScheduler(mode, entry) {
  if (process.platform !== "win32") return;
  const powershell = path.join(
    process.env.SystemRoot || "C:\\Windows",
    "System32",
    "WindowsPowerShell",
    "v1.0",
    "powershell.exe",
  );
  const args = [
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-WindowStyle",
    "Hidden",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    SCHEDULER_SCRIPT,
    "-Mode",
    mode,
    "-CreditKey",
    entry.taskKey,
  ];
  if (mode === "Register") args.push("-ExpiresAt", String(entry.expiresAt));
  await runHidden(powershell, args, { timeoutMs: 30_000 });
}

async function scheduleCredit(state, entry) {
  if (entry.scheduledFor === entry.expiresAt) return;
  try {
    await invokeScheduler("Register", entry);
    entry.scheduledFor = entry.expiresAt;
    await log("credit-scheduled", `${entry.taskKey} expires ${entry.expiresAt}`);
  } catch (error) {
    await log("credit-schedule-failed", error.message);
    throw error;
  }
}

async function removeCreditSchedule(entry) {
  try {
    await invokeScheduler("Remove", entry);
  } catch (error) {
    await log("credit-unschedule-failed", error.message);
  }
  entry.scheduledFor = null;
}

async function detectQuotaChanges(state, currentWindows, observedAt) {
  const drops = findQuotaDrops(state.quotaWindows, currentWindows);
  if (drops.length > 0) {
    const fields = drops.map(({ previous, current, drop }) => ({
      name: current.label,
      value: [
        `사용량: **${previous.usedPercent}% → ${current.usedPercent}%** (-${drop.toFixed(1).replace(/\.0$/, "")}%)`,
        current.resetsAt ? `다음 예정 리셋:\n${discordTime(current.resetsAt)}` : "다음 예정 리셋: 알 수 없음",
      ].join("\n"),
      inline: false,
    }));
    await sendOrQueue(
      state,
      makeDiscordPayload({
        title: "📉 실제 Codex 할당량 감소 감지",
        description:
          "개인 Codex 계정의 실제 사용률이 이전 확인보다 낮아졌습니다. 상시 감시가 아니므로 실제 변경은 이전 확인과 아래 감지 시각 사이에 발생했습니다.",
        color: 0x2ecc71,
        fields: [
          ...fields,
          { name: "감지 시각", value: discordTime(observedAt), inline: false },
        ],
      }),
    );
  }
  state.quotaWindows = currentWindows;
  state.lastQuotaObservedAt = observedAt;
}

async function sendWarning(state, entry, credit, windows, warning, remainingSeconds) {
  const expiresAt = Math.trunc(credit.expiresAt);
  const autoConsumeAt = expiresAt - AUTO_CONSUME_LEAD_SECONDS;
  const description = [
    `실제 Codex 계정의 리셋 티켓이 **${warning.label} 이내**에 만료됩니다.`,
    `현재 남은 시간: **${formatRemaining(remainingSeconds)}**`,
  ].join("\n");
  await sendOrQueue(
    state,
    makeDiscordPayload({
      title: `⏳ Codex 리셋 티켓 · 만료 ${warning.label} 전`,
      description,
      color: warning.seconds <= 3600 ? 0xe67e22 : 0xf1c40f,
      fields: [
        { name: "티켓 만료", value: discordTime(expiresAt), inline: false },
        {
          name: "자동사용 예정",
          value: `${discordTime(autoConsumeAt)}\n만료 1분 전에 실제 계정으로 사용을 시도합니다.`,
          inline: false,
        },
        ...quotaFields(windows),
      ],
    }),
  );
  await log("ticket-warning", `${entry.taskKey} ${warning.label}`);
}

async function handleWarningIfDue(state, entry, credit, windows, now = nowUnix()) {
  const remaining = credit.expiresAt - now;
  const decision = getWarningDecision(remaining, entry.handledThresholds);
  if (!decision.warning) return false;

  await sendWarning(state, entry, credit, windows, decision.warning, remaining);
  entry.handledThresholds = Array.from(
    new Set([...entry.handledThresholds, ...decision.markHandled]),
  ).sort((left, right) => right - left);
  return true;
}

async function sendTicketUnavailable(state, entry, reason, windows = []) {
  if (entry.unavailableAlertedAt) return;
  await sendOrQueue(
    state,
    makeDiscordPayload({
      title: "ℹ️ Codex 리셋 티켓 상태 변경",
      description: reason,
      color: 0x95a5a6,
      fields: [
        { name: "원래 만료 시각", value: discordTime(entry.expiresAt), inline: false },
        ...quotaFields(windows),
      ],
    }),
  );
  entry.unavailableAlertedAt = new Date().toISOString();
}

function findExactCredit(response, entry) {
  return listAvailableExpiringCredits(response).find(
    (credit) => credit.id === entry.id && Math.trunc(credit.expiresAt) === entry.expiresAt,
  );
}

function creditFromState(entry) {
  return {
    id: entry.id,
    expiresAt: entry.expiresAt,
    status: "available",
    resetType: "codexRateLimits",
    title: entry.title,
  };
}

async function runProbe() {
  const state = await loadState();
  const observedAt = nowUnix();
  const response = await readRateLimits();
  const windows = getQuotaWindows(response);
  const credits = listAvailableExpiringCredits(response);
  const activeTaskKeys = new Set();
  let immediateConsumeKey = null;

  for (const credit of credits) {
    const entry = ensureCreditEntry(state, credit);
    activeTaskKeys.add(entry.taskKey);
    if (!immediateConsumeKey && shouldAutoConsume(credit.expiresAt - observedAt)) {
      immediateConsumeKey = entry.taskKey;
    }
  }

  // An expiring ticket always takes priority over logs, Discord outbox delivery,
  // quota-change messages, and task maintenance.
  await saveState(state);
  if (immediateConsumeKey) {
    await runConsume(immediateConsumeKey);
    await log("probe-prioritized-consume", immediateConsumeKey);
    return;
  }

  await detectQuotaChanges(state, windows, observedAt);
  for (const credit of credits) {
    const entry = ensureCreditEntry(state, credit);
    await scheduleCredit(state, entry);
    await handleWarningIfDue(state, entry, credit, windows, observedAt);
  }

  for (const entry of Object.values(state.credits)) {
    if (
      entry.scheduledFor &&
      !activeTaskKeys.has(entry.taskKey) &&
      (entry.expiresAt <= observedAt || entry.consume?.completed)
    ) {
      await removeCreditSchedule(entry);
    }
  }

  state.lastProbeAt = observedAt;
  await saveState(state);
  await flushOutbox(state);
  await saveState(state);
  await log("probe-complete", `${activeTaskKeys.size} active expiring credit(s)`);
}

async function runWarningEvent(taskKey) {
  const state = await loadState();
  const entry = state.credits[taskKey];
  if (!entry) {
    await log("warning-entry-missing", taskKey);
    return;
  }
  if (entry.consume?.completed) {
    await removeCreditSchedule(entry);
    await saveState(state);
    return;
  }

  const response = await readRateLimits();
  const observedAt = nowUnix();
  const windows = getQuotaWindows(response);
  const listedCredit = findExactCredit(response, entry);
  const credit = listedCredit || (!isCreditListComplete(response) ? creditFromState(entry) : null);

  if (credit && shouldAutoConsume(credit.expiresAt - observedAt)) {
    await saveState(state);
    await runConsume(taskKey);
    return;
  }

  await detectQuotaChanges(state, windows, observedAt);

  if (!credit) {
    await sendTicketUnavailable(
      state,
      entry,
      "예약된 티켓이 실제 계정에서 더 이상 사용 가능 상태가 아닙니다. 이미 수동으로 사용했거나 만료되었을 수 있습니다.",
      windows,
    );
    await removeCreditSchedule(entry);
  } else if (credit.expiresAt <= observedAt) {
    await sendTicketUnavailable(
      state,
      entry,
      "예약된 티켓은 이미 만료되어 자동사용 요청을 보내지 않았습니다.",
      windows,
    );
    await removeCreditSchedule(entry);
  } else {
    await handleWarningIfDue(state, entry, credit, windows, observedAt);
  }

  await saveState(state);
  await flushOutbox(state);
  await saveState(state);
}

async function waitUntil(unixSeconds) {
  while (true) {
    const milliseconds = unixSeconds * 1000 - Date.now();
    if (milliseconds <= 0) return;
    await sleep(Math.min(milliseconds, 30_000));
  }
}

async function sendConsumeResult(state, entry, outcome, windows, details) {
  const success = outcome === "reset";
  const title = success
    ? "✅ Codex 리셋 티켓 자동사용 완료"
    : outcome === "nothingToReset"
      ? "⚠️ Codex 리셋 티켓 자동사용 불가"
      : "ℹ️ Codex 리셋 티켓 자동사용 결과";
  const color = success ? 0x2ecc71 : outcome === "nothingToReset" ? 0xe74c3c : 0x95a5a6;
  await sendOrQueue(
    state,
    makeDiscordPayload({
      title,
      description: details,
      color,
      fields: [
        { name: "티켓 만료", value: discordTime(entry.expiresAt), inline: false },
        { name: "처리 결과", value: `\`${outcome}\``, inline: false },
        ...quotaFields(windows),
      ],
    }),
  );
}

async function runConsume(taskKey) {
  if (isMonitorDisabled()) {
    await log("consume-cancelled", "monitor is disabled");
    return;
  }
  const state = await loadState();
  const entry = state.credits[taskKey];
  if (!entry) {
    await log("consume-entry-missing", taskKey);
    return;
  }
  if (entry.consume?.completed) {
    await removeCreditSchedule(entry);
    await saveState(state);
    return;
  }

  const initialRemaining = entry.expiresAt - nowUnix();
  if (initialRemaining > AUTO_CONSUME_PREPARE_SECONDS + 10) {
    await log(
      "consume-too-early",
      `${taskKey} has ${initialRemaining}s remaining; scheduled task will handle it later`,
    );
    return;
  }

  const target = entry.expiresAt - AUTO_CONSUME_LEAD_SECONDS;
  let lastWindows = [];
  let baselineWindows = [];
  let finalOutcome = null;
  let definitiveDetails = "";

  if (initialRemaining <= 0) {
    if (entry.consume.inFlightIdempotencyKey) {
      for (let recoveryAttempt = 0; recoveryAttempt < 3 && !finalOutcome; recoveryAttempt += 1) {
        if (isMonitorDisabled()) return;
        try {
          await withAppServer(async (client) => {
            const result = await client.consumeResetCredit(
              entry.id,
              entry.consume.inFlightIdempotencyKey,
            );
            finalOutcome = result?.outcome || "unknown";
            const current = await client.readRateLimits().catch(() => null);
            if (current) lastWindows = getQuotaWindows(current);
            definitiveDetails =
              finalOutcome === "reset"
                ? "만료 전 보낸 요청의 같은 멱등성 키로 결과를 다시 조회했고, 서버가 리셋 성공을 확인했습니다."
                : `만료 전 보낸 요청의 같은 멱등성 키로 결과를 다시 조회했습니다: \`${finalOutcome}\``;
          });
        } catch (error) {
          await log("expired-consume-recovery-failed", error.message);
          if (recoveryAttempt < 2) await sleep(2000);
        }
      }
      if (!finalOutcome) {
        finalOutcome = "requestStatusUnknown";
        definitiveDetails =
          "만료 전에 요청을 보낸 기록은 있지만 같은 멱등성 키로도 최종 서버 결과를 회수하지 못했습니다. 중복 요청은 보내지 않았습니다.";
      }
    } else {
      finalOutcome = "expired";
      definitiveDetails =
        "PC 절전·종료 또는 지연 때문에 티켓 만료 전에 자동사용 요청을 시작하지 못했습니다.";
    }
  }

  // The task starts five minutes early. Keep the initialized app-server ready,
  // then send consume immediately when the backend clock reaches T-60 seconds.
  while (!finalOutcome && nowUnix() < entry.expiresAt) {
    if (isMonitorDisabled()) {
      await log("consume-cancelled", "disabled while waiting");
      return;
    }
    try {
      await withAppServer(async (client) => {
        const before = await client.readRateLimits();
        baselineWindows = getQuotaWindows(before);
        lastWindows = baselineWindows;

        if (nowUnix() < target) await waitUntil(target);

        while (!finalOutcome && nowUnix() < entry.expiresAt) {
          if (isMonitorDisabled()) return;
          const remaining = entry.expiresAt - nowUnix();
          if (!shouldAutoConsume(remaining)) {
            await waitUntil(target);
            continue;
          }

          if (!entry.consume.inFlightIdempotencyKey) {
            entry.consume.inFlightIdempotencyKey = randomUUID();
            entry.consume.attempts = Number(entry.consume.attempts || 0) + 1;
            await saveState(state);
          }

          if (isMonitorDisabled()) return;

          const result = await client.consumeResetCredit(
            entry.id,
            entry.consume.inFlightIdempotencyKey,
          );
          const outcome = result?.outcome || "unknown";
          await log("consume-response", `${taskKey} ${outcome}`);

          if (outcome === "reset") {
            finalOutcome = outcome;
            let snapshotChanged = false;
            for (let attempt = 0; attempt < 6; attempt += 1) {
              await sleep(attempt === 0 ? 1000 : 2500);
              try {
                const after = await client.readRateLimits();
                lastWindows = getQuotaWindows(after);
                if (findQuotaDrops(baselineWindows, lastWindows).length > 0) {
                  snapshotChanged = true;
                  break;
                }
              } catch (error) {
                await log("post-reset-read-failed", error.message);
              }
            }
            definitiveDetails = snapshotChanged
              ? "만료 1분 전에 실제 Codex 계정으로 티켓을 사용했고, 서버 응답과 사용률 감소를 모두 확인했습니다."
              : "만료 1분 전에 실제 Codex 계정으로 티켓을 사용했고 서버가 리셋을 확인했습니다. 다만 후속 조회 15초 안에는 사용률 변화가 아직 반영되지 않았습니다.";
          } else if (outcome === "alreadyRedeemed" || outcome === "noCredit") {
            finalOutcome = outcome;
            definitiveDetails =
              outcome === "alreadyRedeemed"
                ? "서버가 이 티켓은 이미 사용되었다고 응답했습니다. 같은 멱등성 키를 사용해 중복 적용은 발생하지 않았습니다."
                : "서버가 사용 가능한 리셋 티켓이 없다고 응답했습니다.";
          } else if (outcome === "nothingToReset") {
            // A successful nothingToReset response completes this logical
            // attempt. Use a new key only for a later re-check before expiry.
            entry.consume.inFlightIdempotencyKey = null;
            await saveState(state);
            const secondsLeft = entry.expiresAt - nowUnix();
            if (secondsLeft <= 2 || entry.consume.attempts >= 4) {
              finalOutcome = outcome;
              definitiveDetails =
                "만료 직전까지 여러 번 확인했지만 초기화할 사용량이 없어 서버가 티켓을 적용하지 않았습니다.";
            } else {
              await sleep(Math.min(20, Math.max(2, secondsLeft - 1)) * 1000);
            }
          } else {
            finalOutcome = outcome;
            definitiveDetails = `서버가 예상하지 못한 결과(\`${outcome}\`)를 반환했습니다.`;
          }
        }
      });
    } catch (error) {
      await log("consume-session-failed", error.message);
      const secondsLeft = entry.expiresAt - nowUnix();
      if (secondsLeft <= 2) {
        finalOutcome = "requestFailed";
        definitiveDetails =
          "같은 멱등성 키로 새 app-server 세션에서 재시도했지만 만료 전에 서버 응답을 확인하지 못했습니다. 중복 적용은 방지했습니다.";
      } else {
        const retryDelay = nowUnix() < target ? Math.min(30, Math.max(2, target - nowUnix())) : 2;
        await sleep(retryDelay * 1000);
      }
    }
  }

  if (!finalOutcome) {
    finalOutcome = "expired";
    definitiveDetails =
      "PC 절전·종료 또는 지연 때문에 티켓 만료 전에 자동사용 요청을 완료하지 못했습니다.";
  }

  entry.consume.completed = true;
  entry.consume.outcome = finalOutcome;
  entry.consume.completedAt = new Date().toISOString();
  entry.consume.inFlightIdempotencyKey = null;
  await sendConsumeResult(state, entry, finalOutcome, lastWindows, definitiveDetails);

  await removeCreditSchedule(entry);
  await saveState(state);
  await flushOutbox(state);
  await saveState(state);
  await log("consume-complete", `${taskKey} ${entry.consume.outcome}`);
}

async function printSnapshot() {
  const response = await readRateLimits();
  const observedAt = nowUnix();
  const snapshot = {
    observedAt: formatKst(observedAt),
    quotaWindows: getQuotaWindows(response).map((window) => ({
      label: window.label,
      usedPercent: window.usedPercent,
      resetsAt: window.resetsAt ? formatKst(window.resetsAt) : null,
      resetsAtUnix: window.resetsAt,
    })),
    resetTickets: listAvailableExpiringCredits(response).map((credit) => ({
      title: credit.title || null,
      status: credit.status,
      expiresAt: formatKst(credit.expiresAt),
      expiresAtUnix: Math.trunc(credit.expiresAt),
      remaining: formatRemaining(credit.expiresAt - observedAt),
      automaticUseAt: formatKst(credit.expiresAt - AUTO_CONSUME_LEAD_SECONDS),
    })),
  };
  process.stdout.write(`${JSON.stringify(snapshot, null, 2)}\n`);
}

function readArgument(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : null;
}

async function main() {
  const command = process.argv[2] || "probe";
  await log("start", command);
  if (command !== "once" && isMonitorDisabled()) {
    await log("disabled-exit", command);
    return;
  }
  if (command === "probe") {
    await runProbe();
  } else if (command === "event") {
    const taskKey = readArgument("--credit-key");
    if (!taskKey) throw new Error("event requires --credit-key");
    await runWarningEvent(taskKey);
  } else if (command === "consume") {
    const taskKey = readArgument("--credit-key");
    if (!taskKey) throw new Error("consume requires --credit-key");
    await runConsume(taskKey);
  } else if (command === "once") {
    await printSnapshot();
  } else {
    throw new Error(`Unknown command: ${command}`);
  }
}

async function runLocked() {
  const release = await acquireMonitorLock();
  try {
    await main();
  } finally {
    await release();
  }
}

runLocked().catch(async (error) => {
  await log("fatal", error?.stack || error?.message || String(error));
  process.stderr.write(`Codex account monitor failed: ${error.message}\n`);
  process.exitCode = 1;
});
