import { describe, expect, it } from "bun:test";
import { formatSocialEngagementCount } from "@/lib/formatSocialEngagementCount";

describe("compact engagement counts", () => {
  for (const [count, expected] of [
    [0, "0"], [1, "1"], [999, "999"], [1_000, "1k"], [1_099, "1k"], [1_100, "1.1k"],
    [1_199, "1.1k"], [9_999, "9.9k"], [10_000, "10k"], [12_999, "12k"], [120_999, "120k"],
    [999_999, "999k"], [1_000_000, "1m"], [1_199_999, "1.1m"], [12_999_999, "12m"],
    [120_999_999, "120m"], [999_999_999, "999m"], [1_000_000_000, "1b"], [1_199_999_999, "1.1b"],
    [12_999_999_999, "12b"], [120_999_999_999, "120b"],
  ] as const) it(`${count} displays as ${expected}`, () => expect(formatSocialEngagementCount(count)).toBe(expected));
  it("handles invalid and fractional counts without overstating them", () => {
    for (const count of [-1, NaN, Infinity]) expect(formatSocialEngagementCount(count)).toBe("0");
    expect(formatSocialEngagementCount(999.9)).toBe("999");
  });
});
