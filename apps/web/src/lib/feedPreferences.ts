import type { PreferencesRecord } from "@/lib/pdsClient";

export const TOP_LEVEL_FEEDS = [
  "readLater",
  "archive",
  "subscribed",
  "following",
] as const;

export type TopLevelFeed = (typeof TOP_LEVEL_FEEDS)[number];
/** Reader navigation also includes server-capability feeds that are not PDS preferences. */
export type ReaderNavigationFeed = TopLevelFeed | "wire" | "circle" | "finance" | "sports" | "podcasts";
export type RssArticleOpenMode = "reader" | "original";

export const TOP_LEVEL_FEED_LABELS: Record<TopLevelFeed, string> = {
  readLater: "Read Later",
  archive: "Archive",
  subscribed: "Subscribed",
  following: "Following",
};

export type FeedDisplayPreferences = {
  showWire: boolean;
  showCircle: boolean;
  showFinance: boolean;
  showSports: boolean;
  hideSportsScores: boolean;
  hideFinancePerformance: boolean;
  hideFinanceCrypto: boolean;
  visibleFeeds: TopLevelFeed[];
  feedsWithUnreadCounts: TopLevelFeed[];
  rssArticleOpenMode: RssArticleOpenMode;
};

export const DEFAULT_FEED_DISPLAY_PREFERENCES: FeedDisplayPreferences = {
  showWire: true,
  showCircle: true,
  showFinance: true,
  showSports: true,
  hideSportsScores: false,
  hideFinancePerformance: false,
  hideFinanceCrypto: false,
  visibleFeeds: [...TOP_LEVEL_FEEDS],
  feedsWithUnreadCounts: [...TOP_LEVEL_FEEDS],
  rssArticleOpenMode: "original",
};

const STORAGE_PREFIX = "the-social-wire.feed-display.v1";

function isTopLevelFeed(value: unknown): value is TopLevelFeed {
  return (
    typeof value === "string" &&
    (TOP_LEVEL_FEEDS as readonly string[]).includes(value)
  );
}

export function isRssArticleOpenMode(
  value: unknown,
): value is RssArticleOpenMode {
  return value === "reader" || value === "original";
}

export function normalizeFeedDisplayPreferences(
  value:
    | Pick<
        PreferencesRecord,
        | "visibleFeeds"
        | "showWire"
        | "showCircle"
        | "showFinance"
        | "showSports"
        | "hideSportsScores"
        | "hideFinancePerformance"
        | "hideFinanceCrypto"
        | "showTopLevelFeedUnreadCounts"
        | "feedsWithUnreadCounts"
        | "rssArticleOpenMode"
      >
    | FeedDisplayPreferences
    | null
    | undefined,
): FeedDisplayPreferences {
  const visibleFeeds = Array.isArray(value?.visibleFeeds)
    ? Array.from(new Set(value.visibleFeeds.filter(isTopLevelFeed)))
    : [...DEFAULT_FEED_DISPLAY_PREFERENCES.visibleFeeds];
  const legacyShowCounts =
    value && "showTopLevelFeedUnreadCounts" in value
      ? value.showTopLevelFeedUnreadCounts
      : undefined;
  const requestedCountFeeds = Array.isArray(value?.feedsWithUnreadCounts)
    ? value.feedsWithUnreadCounts.filter(isTopLevelFeed)
    : (legacyShowCounts ?? true)
      ? visibleFeeds
      : [];
  const requestedCountFeedSet = new Set(requestedCountFeeds);
  return {
    showWire: value?.showWire !== false,
    showCircle: value?.showCircle !== false,
    showFinance: value?.showFinance !== false,
    showSports: value?.showSports !== false,
    hideSportsScores: value?.hideSportsScores === true,
    hideFinancePerformance: value?.hideFinancePerformance === true,
    hideFinanceCrypto: value?.hideFinanceCrypto === true,
    visibleFeeds,
    feedsWithUnreadCounts: TOP_LEVEL_FEEDS.filter(
      (feed) =>
        visibleFeeds.includes(feed) &&
        requestedCountFeedSet.has(feed),
    ),
    rssArticleOpenMode: isRssArticleOpenMode(value?.rssArticleOpenMode)
      ? value.rssArticleOpenMode
      : DEFAULT_FEED_DISPLAY_PREFERENCES.rssArticleOpenMode,
  };
}

export function feedDisplaysUnreadCount(
  preferences: FeedDisplayPreferences,
  feed: TopLevelFeed,
): boolean {
  return (
    preferences.visibleFeeds.includes(feed) &&
    preferences.feedsWithUnreadCounts.includes(feed)
  );
}

export function nextVisibleFeed(
  hiddenFeed: TopLevelFeed,
  visibleFeeds: readonly TopLevelFeed[],
): TopLevelFeed {
  const visible = new Set(visibleFeeds);
  const start = TOP_LEVEL_FEEDS.indexOf(hiddenFeed);
  for (let offset = 1; offset <= TOP_LEVEL_FEEDS.length; offset += 1) {
    const candidate =
      TOP_LEVEL_FEEDS[(start + offset) % TOP_LEVEL_FEEDS.length]!;
    if (visible.has(candidate)) return candidate;
  }
  return "subscribed";
}

export function loadCachedFeedDisplayPreferences(
  storage: Pick<Storage, "getItem">,
  viewerDid: string,
): FeedDisplayPreferences | null {
  try {
    const raw = storage.getItem(`${STORAGE_PREFIX}:${viewerDid}`);
    return raw
      ? normalizeFeedDisplayPreferences(
          JSON.parse(raw) as FeedDisplayPreferences,
        )
      : null;
  } catch {
    return null;
  }
}

export function saveCachedFeedDisplayPreferences(
  storage: Pick<Storage, "setItem">,
  viewerDid: string,
  preferences: FeedDisplayPreferences,
): void {
  try {
    storage.setItem(
      `${STORAGE_PREFIX}:${viewerDid}`,
      JSON.stringify(normalizeFeedDisplayPreferences(preferences)),
    );
  } catch {
    // Private browsing and quota failures must not block reader navigation.
  }
}
