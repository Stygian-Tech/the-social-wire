import { describe, expect, test } from "bun:test";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  nextVisibleFeed,
  normalizeFeedDisplayPreferences,
} from "@/lib/feedPreferences";

describe("feed display preferences", () => {
  test("defaults absent additive fields", () => {
    expect(normalizeFeedDisplayPreferences(undefined)).toEqual(
      DEFAULT_FEED_DISPLAY_PREFERENCES,
    );
  });

  test("rejects an empty visible feed list", () => {
    expect(
      normalizeFeedDisplayPreferences({
        visibleFeeds: [],
        showTopLevelFeedUnreadCounts: false,
      }),
    ).toEqual({
      visibleFeeds: DEFAULT_FEED_DISPLAY_PREFERENCES.visibleFeeds,
      showTopLevelFeedUnreadCounts: false,
    });
  });

  test("selects the next visible feed in canonical circular order", () => {
    expect(nextVisibleFeed("archive", ["readLater", "following"])).toBe(
      "following",
    );
    expect(nextVisibleFeed("following", ["readLater", "subscribed"])).toBe(
      "readLater",
    );
  });
});
