import { expect, it } from "bun:test";
import { socialRelativeTime } from "@/components/Social/socialRelativeTime";

it("uses elapsed seconds, minutes, hours, days, months and years at each boundary", () => {
  const now = Date.parse("2026-10-10T12:00:00Z");
  for (const [seconds, expected] of [
    [0, "0s"], [59, "59s"], [60, "1m"], [3599, "59m"],
    [3600, "1h"], [86399, "23h"], [86400, "1d"],
    [29 * 86400, "29d"], [30 * 86400, "1mo"],
    [364 * 86400, "12mo"], [365 * 86400, "1y"],
    [730 * 86400, "2y"],
  ] as const) expect(socialRelativeTime(now - seconds * 1000, now)).toBe(expected);
  expect(socialRelativeTime(now + 60_000, now)).toBe("0s");
  expect(socialRelativeTime(NaN, now)).toBe("");
});
