export const LIVE_TIMESTAMP_FORMATS = ["time-24", "time-12", "date-time", "iso"] as const;
export type LiveTimestampFormat = typeof LIVE_TIMESTAMP_FORMATS[number];
export type LiveTimestampSettings = { timestampFormat: LiveTimestampFormat; timeZone: string };

export function localLiveTimeZone(): string {
  return Intl.DateTimeFormat().resolvedOptions().timeZone;
}

export function validateLiveTimestampSettings(value: { timestampFormat?: unknown; timeZone?: unknown }): void {
  if (value.timestampFormat !== undefined && !LIVE_TIMESTAMP_FORMATS.includes(value.timestampFormat as LiveTimestampFormat)) throw new Error("Choose a valid timestamp format.");
  if (value.timeZone !== undefined) {
    if (typeof value.timeZone !== "string" || !value.timeZone || value.timeZone.length > 128 || /^[+-]/.test(value.timeZone)) throw new Error("Choose a valid IANA time zone, such as America/Chicago.");
    try { new Intl.DateTimeFormat("en", { timeZone: value.timeZone }); }
    catch { throw new Error("Choose a valid IANA time zone, such as America/Chicago."); }
  }
}

export function liveTimestampSettings(value: Partial<LiveTimestampSettings> = {}): LiveTimestampSettings {
  validateLiveTimestampSettings(value);
  return { timestampFormat: value.timestampFormat ?? "time-24", timeZone: value.timeZone ?? localLiveTimeZone() };
}

/** Fixed locale and h23 keep retries deterministic, including midnight and DST. */
export function formatLiveTimestamp(timestamp: string, settings: LiveTimestampSettings): string {
  validateLiveTimestampSettings(settings);
  const date = new Date(timestamp);
  if (!Number.isFinite(date.getTime())) throw new Error("Invalid live update timestamp.");
  if (settings.timestampFormat === "iso") return date.toISOString();
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: settings.timeZone, hour: "2-digit", minute: "2-digit",
    hourCycle: settings.timestampFormat === "time-12" ? "h12" : "h23",
    ...(settings.timestampFormat === "date-time" ? { year: "numeric", month: "2-digit", day: "2-digit" } as const : {}),
  }).formatToParts(date);
  const part = (type: Intl.DateTimeFormatPartTypes) => parts.find(value => value.type === type)?.value ?? "";
  const time = `${part("hour")}:${part("minute")}`;
  if (settings.timestampFormat === "time-12") return `${time} ${part("dayPeriod")}`;
  return settings.timestampFormat === "date-time" ? `${part("year")}-${part("month")}-${part("day")} ${time}` : time;
}
