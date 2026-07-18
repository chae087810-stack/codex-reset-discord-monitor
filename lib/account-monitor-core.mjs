export const ALERT_THRESHOLDS = Object.freeze([
  Object.freeze({ seconds: 24 * 60 * 60, label: "24시간" }),
  Object.freeze({ seconds: 12 * 60 * 60, label: "12시간" }),
  Object.freeze({ seconds: 6 * 60 * 60, label: "6시간" }),
  Object.freeze({ seconds: 60 * 60, label: "1시간" }),
  Object.freeze({ seconds: 30 * 60, label: "30분" }),
]);

export const AUTO_CONSUME_LEAD_SECONDS = 60;
export const AUTO_CONSUME_PREPARE_SECONDS = 5 * 60;

export function makeCreditKey(credit) {
  if (!credit || typeof credit.id !== "string" || !Number.isFinite(credit.expiresAt)) {
    return null;
  }
  return `${credit.id}:${Math.trunc(credit.expiresAt)}`;
}

export function listAvailableExpiringCredits(rateLimitResponse) {
  const credits = rateLimitResponse?.rateLimitResetCredits?.credits;
  if (!Array.isArray(credits)) return [];

  return credits
    .filter(
      (credit) =>
        credit &&
        credit.status === "available" &&
        credit.resetType === "codexRateLimits" &&
        typeof credit.id === "string" &&
        Number.isFinite(credit.expiresAt),
    )
    .sort((left, right) => left.expiresAt - right.expiresAt);
}

export function isCreditListComplete(rateLimitResponse) {
  const summary = rateLimitResponse?.rateLimitResetCredits;
  if (!summary || !Array.isArray(summary.credits)) return false;
  const availableCount = Number(summary.availableCount);
  return Number.isFinite(availableCount) && summary.credits.length >= availableCount;
}

export function getWarningDecision(remainingSeconds, handledThresholds = []) {
  if (!Number.isFinite(remainingSeconds)) {
    return { warning: null, markHandled: [] };
  }

  if (
    remainingSeconds <= AUTO_CONSUME_LEAD_SECONDS ||
    remainingSeconds > ALERT_THRESHOLDS[0].seconds
  ) {
    return { warning: null, markHandled: [] };
  }

  const handled = new Set(handledThresholds.map(Number));
  const crossed = ALERT_THRESHOLDS.filter(
    (threshold) => remainingSeconds <= threshold.seconds,
  );
  const unhandled = crossed.filter((threshold) => !handled.has(threshold.seconds));

  if (unhandled.length === 0) {
    return { warning: null, markHandled: [] };
  }

  // If the PC was asleep, send only the closest useful warning instead of a backlog.
  const warning = unhandled.reduce((closest, threshold) =>
    threshold.seconds < closest.seconds ? threshold : closest,
  );

  return {
    warning,
    markHandled: crossed.map((threshold) => threshold.seconds),
  };
}

export function shouldAutoConsume(remainingSeconds) {
  return (
    Number.isFinite(remainingSeconds) &&
    remainingSeconds > 0 &&
    remainingSeconds <= AUTO_CONSUME_LEAD_SECONDS
  );
}

export function rateWindowLabel(window, fallback = "할당량") {
  const minutes = Number(window?.windowDurationMins);
  if (!Number.isFinite(minutes) || minutes <= 0) return fallback;
  if (minutes === 60) return "1시간 한도";
  if (minutes === 300) return "5시간 한도";
  if (minutes === 1440) return "일일 한도";
  if (minutes === 10080) return "주간 한도";
  if (minutes % 1440 === 0) return `${minutes / 1440}일 한도`;
  if (minutes % 60 === 0) return `${minutes / 60}시간 한도`;
  return `${minutes}분 한도`;
}

export function getQuotaWindows(rateLimitResponse) {
  const byLimitId = rateLimitResponse?.rateLimitsByLimitId;
  const mappedGroups =
    byLimitId && typeof byLimitId === "object"
      ? Object.entries(byLimitId)
          .filter(([, snapshot]) => snapshot && typeof snapshot === "object")
          .map(([mapKey, snapshot]) => ({ mapKey, snapshot }))
      : [];
  const groups =
    mappedGroups.length > 0
      ? mappedGroups
      : rateLimitResponse?.rateLimits
        ? [{ mapKey: "default", snapshot: rateLimitResponse.rateLimits }]
        : [];
  const showGroupName = groups.length > 1;
  const windows = [];

  for (const { mapKey, snapshot } of groups) {
    const groupId = snapshot.limitId || mapKey;
    const groupName = snapshot.limitName || (groupId === "codex" ? "Codex" : null);
    for (const entry of [
      { role: "primary", fallback: "기본 한도", window: snapshot.primary },
      { role: "secondary", fallback: "보조 한도", window: snapshot.secondary },
    ]) {
      if (!entry.window || !Number.isFinite(entry.window.usedPercent)) continue;
      const windowLabel = rateWindowLabel(entry.window, entry.fallback);
      windows.push({
        key: `${groupId}:${entry.role}`,
        label: showGroupName && groupName ? `${groupName} · ${windowLabel}` : windowLabel,
        usedPercent: Number(entry.window.usedPercent),
        resetsAt: Number.isFinite(entry.window.resetsAt)
          ? Math.trunc(entry.window.resetsAt)
          : null,
        windowDurationMins: Number.isFinite(entry.window.windowDurationMins)
          ? Number(entry.window.windowDurationMins)
          : null,
      });
    }
  }

  return windows;
}

export function findQuotaDrops(previousWindows = [], currentWindows = []) {
  const previousByKey = new Map(previousWindows.map((window) => [window.key, window]));
  const drops = [];

  for (const current of currentWindows) {
    const previous = previousByKey.get(current.key);
    if (!previous) continue;
    const drop = previous.usedPercent - current.usedPercent;
    if (drop >= 1) {
      drops.push({ previous, current, drop });
    }
  }

  return drops;
}

export function formatKst(unixSeconds) {
  const value = Number(unixSeconds);
  if (!Number.isFinite(value)) return "알 수 없음";

  const parts = new Intl.DateTimeFormat("ko-KR", {
    timeZone: "Asia/Seoul",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    weekday: "short",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date(Math.trunc(value) * 1000));

  const part = (type) => parts.find((item) => item.type === type)?.value ?? "";
  return `${part("year")}-${part("month")}-${part("day")} (${part("weekday")}) ${part("hour")}:${part("minute")}:${part("second")} KST`;
}

export function discordTime(unixSeconds) {
  const value = Math.trunc(Number(unixSeconds));
  if (!Number.isFinite(value)) return "알 수 없음";
  return `${formatKst(value)}\n<t:${value}:F> (<t:${value}:R>)`;
}

export function formatRemaining(seconds) {
  let remaining = Math.max(0, Math.ceil(Number(seconds) || 0));
  const days = Math.floor(remaining / 86400);
  remaining %= 86400;
  const hours = Math.floor(remaining / 3600);
  remaining %= 3600;
  const minutes = Math.floor(remaining / 60);
  const secs = remaining % 60;

  const values = [];
  if (days) values.push(`${days}일`);
  if (hours) values.push(`${hours}시간`);
  if (minutes) values.push(`${minutes}분`);
  if (secs || values.length === 0) values.push(`${secs}초`);
  return values.join(" ");
}
