import test from "node:test";
import assert from "node:assert/strict";

import {
  ALERT_THRESHOLDS,
  discordTime,
  findQuotaDrops,
  formatKst,
  getQuotaWindows,
  getWarningDecision,
  isCreditListComplete,
  listAvailableExpiringCredits,
  makeCreditKey,
  rateWindowLabel,
  shouldAutoConsume,
} from "../lib/account-monitor-core.mjs";

test("warning thresholds include the requested final-day alerts", () => {
  assert.deepEqual(
    ALERT_THRESHOLDS.map((threshold) => threshold.seconds),
    [86400, 43200, 21600, 3600, 1800],
  );
});

test("no warning is sent outside the final 24 hours", () => {
  assert.equal(getWarningDecision(86401).warning, null);
  assert.equal(getWarningDecision(86400).warning.label, "24시간");
});

test("a resumed PC receives only the closest useful warning", () => {
  const fiveHours = getWarningDecision(5 * 3600);
  assert.equal(fiveHours.warning.label, "6시간");
  assert.deepEqual(fiveHours.markHandled, [86400, 43200, 21600]);

  const twentyMinutes = getWarningDecision(20 * 60);
  assert.equal(twentyMinutes.warning.label, "30분");
  assert.deepEqual(twentyMinutes.markHandled, [86400, 43200, 21600, 3600, 1800]);
});

test("handled thresholds are not repeated after restart", () => {
  assert.equal(getWarningDecision(6 * 3600, [86400, 43200, 21600]).warning, null);
  assert.equal(getWarningDecision(3600, [86400, 43200, 21600]).warning.label, "1시간");
});

test("automatic consumption starts only inside the last minute", () => {
  assert.equal(shouldAutoConsume(61), false);
  assert.equal(shouldAutoConsume(60), true);
  assert.equal(shouldAutoConsume(1), true);
  assert.equal(shouldAutoConsume(0), false);
  assert.equal(getWarningDecision(50).warning, null);
});

test("only available Codex reset credits with an expiry are selected", () => {
  const response = {
    rateLimitResetCredits: {
      credits: [
        { id: "later", expiresAt: 300, status: "available", resetType: "codexRateLimits" },
        { id: "used", expiresAt: 100, status: "redeemed", resetType: "codexRateLimits" },
        { id: "other", expiresAt: 50, status: "available", resetType: "unknown" },
        { id: "never", expiresAt: null, status: "available", resetType: "codexRateLimits" },
        { id: "earlier", expiresAt: 200, status: "available", resetType: "codexRateLimits" },
      ],
    },
  };
  const credits = listAvailableExpiringCredits(response);
  assert.deepEqual(credits.map((credit) => credit.id), ["earlier", "later"]);
  assert.equal(makeCreditKey(credits[0]), "earlier:200");
});

test("a capped or nullable credit list is treated as incomplete", () => {
  assert.equal(
    isCreditListComplete({ rateLimitResetCredits: { availableCount: 3, credits: null } }),
    false,
  );
  assert.equal(
    isCreditListComplete({
      rateLimitResetCredits: { availableCount: 3, credits: [{ id: "1" }, { id: "2" }] },
    }),
    false,
  );
  assert.equal(
    isCreditListComplete({
      rateLimitResetCredits: {
        availableCount: 2,
        credits: [{ id: "1" }, { id: "2" }],
      },
    }),
    true,
  );
});

test("KST and Discord timestamps preserve the exact backend second", () => {
  const timestamp = Date.parse("2026-07-20T05:03:27Z") / 1000;
  assert.equal(formatKst(timestamp), "2026-07-20 (월) 14:03:27 KST");
  assert.match(discordTime(timestamp), /<t:1784523807:F> \(<t:1784523807:R>\)/);

  const midnight = Date.parse("2026-07-19T15:00:00Z") / 1000;
  assert.equal(formatKst(midnight), "2026-07-20 (월) 00:00:00 KST");
});

test("quota windows use durations instead of primary/secondary guesses", () => {
  assert.equal(rateWindowLabel({ windowDurationMins: 300 }), "5시간 한도");
  assert.equal(rateWindowLabel({ windowDurationMins: 10080 }), "주간 한도");
  assert.equal(rateWindowLabel({ windowDurationMins: 2880 }), "2일 한도");

  const windows = getQuotaWindows({
    rateLimits: {
      primary: { usedPercent: 75, resetsAt: 2000, windowDurationMins: 300 },
      secondary: { usedPercent: 40, resetsAt: 3000, windowDurationMins: 10080 },
    },
  });
  assert.deepEqual(windows.map((window) => window.label), ["5시간 한도", "주간 한도"]);
});

test("per-model quota groups are included without duplicating the default group", () => {
  const windows = getQuotaWindows({
    rateLimits: {
      limitId: "codex",
      primary: { usedPercent: 51, resetsAt: 3000, windowDurationMins: 10080 },
    },
    rateLimitsByLimitId: {
      codex_bengalfox: {
        limitId: "codex_bengalfox",
        limitName: "GPT-5.3-Codex-Spark",
        primary: { usedPercent: 0, resetsAt: 2000, windowDurationMins: 10080 },
      },
      codex: {
        limitId: "codex",
        limitName: null,
        primary: { usedPercent: 51, resetsAt: 3000, windowDurationMins: 10080 },
      },
    },
  });

  assert.deepEqual(
    windows.map((window) => window.label),
    ["GPT-5.3-Codex-Spark · 주간 한도", "Codex · 주간 한도"],
  );
  assert.equal(windows.length, 2);
});

test("real quota decreases are detected while sub-percent jitter is ignored", () => {
  const previous = [
    { key: "primary", label: "5시간 한도", usedPercent: 80, resetsAt: 1000 },
    { key: "secondary", label: "주간 한도", usedPercent: 50, resetsAt: 2000 },
  ];
  const current = [
    { key: "primary", label: "5시간 한도", usedPercent: 10, resetsAt: 3000 },
    { key: "secondary", label: "주간 한도", usedPercent: 49.5, resetsAt: 2000 },
  ];
  const drops = findQuotaDrops(previous, current);
  assert.equal(drops.length, 1);
  assert.equal(drops[0].drop, 70);
});
