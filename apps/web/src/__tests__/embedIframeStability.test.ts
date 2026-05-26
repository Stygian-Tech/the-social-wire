import { describe, expect, it } from "bun:test";
import {
  clearUnstableEmbedCacheForTests,
  IFRAME_LOAD_STORM_MAX_LOADS,
  IFRAME_LOAD_STORM_WINDOW_MS,
  isCachedUnstableEmbed,
  markUnstableEmbed,
  registerIframeLoadEvent,
} from "@/lib/embedIframeStability";

describe("embedIframeStability", () => {
  it("marks unstable after repeated loads within the storm window", () => {
    const t0 = 1_000_000;
    let timestamps: number[] = [];
    for (let i = 0; i < IFRAME_LOAD_STORM_MAX_LOADS - 1; i++) {
      const result = registerIframeLoadEvent(timestamps, t0 + i * 100);
      timestamps = result.timestamps;
      expect(result.unstable).toBe(false);
    }
    const final = registerIframeLoadEvent(timestamps, t0 + 500);
    expect(final.unstable).toBe(true);
    expect(final.timestamps).toHaveLength(IFRAME_LOAD_STORM_MAX_LOADS);
  });

  it("drops load events outside the storm window", () => {
    const t0 = 1_000_000;
    let timestamps: number[] = [];
    for (let i = 0; i < IFRAME_LOAD_STORM_MAX_LOADS - 1; i++) {
      const result = registerIframeLoadEvent(timestamps, t0);
      timestamps = result.timestamps;
    }
    const afterWindow = registerIframeLoadEvent(
      timestamps,
      t0 + IFRAME_LOAD_STORM_WINDOW_MS + 1
    );
    expect(afterWindow.unstable).toBe(false);
    expect(afterWindow.timestamps).toHaveLength(1);
  });

  it("caches unstable embed URLs for the session", () => {
    clearUnstableEmbedCacheForTests();
    expect(isCachedUnstableEmbed("https://example.com/a")).toBe(false);
    markUnstableEmbed("https://example.com/a");
    expect(isCachedUnstableEmbed("https://example.com/a")).toBe(true);
  });
});
