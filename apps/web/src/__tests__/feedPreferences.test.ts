import { describe, expect, test } from "bun:test";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  feedDisplaysUnreadCount,
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
      feedsWithUnreadCounts: [],
      rssArticleOpenMode: "reader",
    });
  });

  test("migrates the legacy global count preference", () => {
    expect(
      normalizeFeedDisplayPreferences({
        visibleFeeds: ["following", "readLater"],
        showTopLevelFeedUnreadCounts: true,
      }),
    ).toEqual({
      visibleFeeds: ["following", "readLater"],
      feedsWithUnreadCounts: ["readLater", "following"],
      rssArticleOpenMode: "reader",
    });
  });

  test("preserves valid RSS article open modes and rejects unknown values", () => {
    expect(
      normalizeFeedDisplayPreferences({
        visibleFeeds: ["following"],
        feedsWithUnreadCounts: ["following"],
        rssArticleOpenMode: "original",
      }).rssArticleOpenMode,
    ).toBe("original");

    expect(
      normalizeFeedDisplayPreferences({
        visibleFeeds: ["following"],
        rssArticleOpenMode: "unknown" as "reader",
      }).rssArticleOpenMode,
    ).toBe("reader");
  });

  test("keeps counts only for visible feeds in canonical order", () => {
    const preferences = normalizeFeedDisplayPreferences({
      visibleFeeds: ["following", "readLater"],
      feedsWithUnreadCounts: ["following", "archive", "readLater"],
    });

    expect(preferences.feedsWithUnreadCounts).toEqual([
      "readLater",
      "following",
    ]);
    expect(feedDisplaysUnreadCount(preferences, "following")).toBe(true);
    expect(feedDisplaysUnreadCount(preferences, "archive")).toBe(false);
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
