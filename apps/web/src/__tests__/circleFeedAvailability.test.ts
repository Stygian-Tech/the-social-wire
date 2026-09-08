import { describe, expect, it } from "bun:test";
import { isCircleNavigationEnabled } from "@/lib/circleFeedAvailability";

describe("Circle navigation availability", () => {
  it("keeps Circle visible while the catalog loads or fails", () => {
    expect(isCircleNavigationEnabled(undefined)).toBe(true);
  });

  it("keeps Circle visible without available stories", () => {
    const catalog = { enabled: true, available: false };
    expect(isCircleNavigationEnabled(catalog)).toBe(true);
  });

  it("honors both the user preference and global disablement", () => {
    expect(isCircleNavigationEnabled({ enabled: true }, false)).toBe(false);
    expect(isCircleNavigationEnabled(undefined, false)).toBe(false);
    expect(isCircleNavigationEnabled({ enabled: false })).toBe(false);
  });
});
