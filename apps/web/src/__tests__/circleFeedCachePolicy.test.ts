import { describe, expect, it } from "bun:test";

import { CIRCLE_STALE_TIME_MS } from "@/hooks/useCircleFeed";

describe("Your Circle cache policy", () => {
  it("keeps client refreshes aligned with the ten-minute graph freshness target", () => {
    expect(CIRCLE_STALE_TIME_MS).toBe(10 * 60_000);
  });
});
