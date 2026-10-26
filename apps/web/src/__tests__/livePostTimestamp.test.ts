import { expect, test } from "bun:test";
import { formatLiveTimestamp, liveTimestampSettings } from "@/lib/livePosts/livePostTimestamp";
import { appendLiveArticleContent } from "@/lib/livePosts/livePostContent";

const settings = { timestampFormat: "time-24" as const, timeZone: "America/Chicago" };
test("24-hour headings are zero padded with no date or seconds, including midnight and DST", () => {
  for (const [iso, expected] of [
    ["2026-10-26T21:05:57.550Z", "16:05"],
    ["2026-10-27T05:00:59Z", "00:00"],
    ["2026-03-08T07:59:00Z", "01:59"],
    ["2026-03-08T08:00:00Z", "03:00"],
    ["2026-11-01T06:30:00Z", "01:30"],
    ["2026-11-01T07:30:00Z", "01:30"],
  ]) expect(formatLiveTimestamp(iso, settings)).toBe(expected);
  expect(formatLiveTimestamp("2026-10-26T21:05:57Z", { ...settings, timeZone: "Asia/Kathmandu" })).toBe("02:50");
});
test("format choices have deterministic previews in the saved timezone", () => {
  const iso = "2026-10-26T21:05:57.550Z";
  expect(formatLiveTimestamp(iso, { ...settings, timestampFormat: "time-12" })).toBe("04:05 PM");
  expect(formatLiveTimestamp(iso, { ...settings, timestampFormat: "date-time" })).toBe("2026-10-26 16:05");
  expect(formatLiveTimestamp(iso, { ...settings, timestampFormat: "iso" })).toBe(iso);
  expect(liveTimestampSettings()).toEqual({ timestampFormat: "time-24", timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone });
  for (const invalid of [{ timestampFormat: "raw" }, { timeZone: "Mars/Unknown" }, { timeZone: "+05:00" }, { timeZone: "" }]) expect(() => liveTimestampSettings(invalid as never)).toThrow();
});
test("all native providers use the same formatted heading", () => {
  const heading = formatLiveTimestamp("2026-10-26T21:05:57.550Z", settings);
  for (const host of ["leaflet", "offprint", "pckt", "markpub", "unknown"] as const) {
    const content = JSON.stringify(appendLiveArticleContent(host, undefined, heading, "Update"));
    expect(content).toContain("16:05"); expect(content).not.toContain("2026-10-26");
  }
});
