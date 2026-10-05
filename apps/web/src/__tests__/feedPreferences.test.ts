import { describe, expect, test } from "bun:test";
import {
  DEFAULT_FEED_DISPLAY_PREFERENCES,
  feedDisplaysUnreadCount,
  nextVisibleFeed,
  normalizeFeedDisplayPreferences,
  loadCachedFeedDisplayPreferences,
  saveCachedFeedDisplayPreferences,
} from "@/lib/feedPreferences";

describe("feed display preferences", () => {
  test("preserves independent discovery visibility without changing legacy feeds", () => {
    for (const showWire of [true, false]) {
      for (const showCircle of [true, false]) {
        const preferences = normalizeFeedDisplayPreferences({
          visibleFeeds: ["following"],
          feedsWithUnreadCounts: [],
          showWire,
          showCircle,
          showFinance: true,
          showSports: true,
          hideSportsScores: false,
          hideFinancePerformance: false,
          hideFinanceCrypto: false,
        });
        expect(preferences).toEqual({
          visibleFeeds: ["following"],
          feedsWithUnreadCounts: [],
          rssArticleOpenMode: "original",
          showWire,
          showCircle,
          showFinance: true,
          showSports: true,
          hideSportsScores: false,
          hideFinancePerformance: false,
          hideFinanceCrypto: false,
        });
        const cache = new Map<string, string>();
        const storage = {
          getItem: (key: string) => cache.get(key) ?? null,
          setItem: (key: string, value: string) => { cache.set(key, value); },
        };
        saveCachedFeedDisplayPreferences(storage, "did:plc:viewer", preferences);
        expect(loadCachedFeedDisplayPreferences(storage, "did:plc:viewer")).toEqual(preferences);
        expect(loadCachedFeedDisplayPreferences(storage, "did:plc:other")).toBeNull();
      }
    }
  });

  test("defaults absent additive fields", () => {
    expect(normalizeFeedDisplayPreferences(undefined)).toEqual(
      DEFAULT_FEED_DISPLAY_PREFERENCES,
    );
  });

  test("preserves an explicit empty visible feed list", () => {
    expect(
      normalizeFeedDisplayPreferences({
        visibleFeeds: [],
        showTopLevelFeedUnreadCounts: false,
      }),
    ).toEqual({
      visibleFeeds: [],
      feedsWithUnreadCounts: [],
      showWire: true,
      showCircle: true,
      showFinance: true,
          showSports: true,
          hideSportsScores: false,
      hideFinancePerformance: false,
          hideFinanceCrypto: false,
      rssArticleOpenMode: "original",
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
      showWire: true,
      showCircle: true,
      showFinance: true,
          showSports: true,
          hideSportsScores: false,
      hideFinancePerformance: false,
          hideFinanceCrypto: false,
      rssArticleOpenMode: "original",
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
    ).toBe("original");
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


test("drops counts for every explicitly hidden feed", () => {
  const preferences = normalizeFeedDisplayPreferences({
    visibleFeeds: ["readLater"],
    feedsWithUnreadCounts: ["subscribed", "following", "archive"],
  });
  expect(preferences.visibleFeeds).toEqual(["readLater"]);
  expect(preferences.feedsWithUnreadCounts).toEqual([]);
  expect(feedDisplaysUnreadCount(preferences, "subscribed")).toBe(false);
  expect(feedDisplaysUnreadCount(preferences, "following")).toBe(false);
  expect(feedDisplaysUnreadCount(preferences, "archive")).toBe(false);
});

 test("crypto hiding is explicit and cached independently per viewer", () => {
   expect(normalizeFeedDisplayPreferences(undefined).hideFinanceCrypto).toBe(false);
   const preferences = normalizeFeedDisplayPreferences({ hideFinanceCrypto: true });
   const cache = new Map<string, string>();
   const storage = { getItem: (key: string) => cache.get(key) ?? null, setItem: (key: string, value: string) => { cache.set(key, value); } };
   saveCachedFeedDisplayPreferences(storage, "did:plc:viewer", preferences);
   expect(loadCachedFeedDisplayPreferences(storage, "did:plc:viewer")?.hideFinanceCrypto).toBe(true);
   expect(loadCachedFeedDisplayPreferences(storage, "did:plc:other")).toBeNull();
 });
