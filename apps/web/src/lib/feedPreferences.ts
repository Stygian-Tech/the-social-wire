import type { PreferencesRecord } from "@/lib/pdsClient";

export const TOP_LEVEL_FEEDS = [
  "readLater",
  "archive",
  "subscribed",
  "following",
] as const;

export type TopLevelFeed = (typeof TOP_LEVEL_FEEDS)[number];

export type FeedDisplayPreferences = {
  visibleFeeds: TopLevelFeed[];
  showTopLevelFeedUnreadCounts: boolean;
};

export const DEFAULT_FEED_DISPLAY_PREFERENCES: FeedDisplayPreferences = {
  visibleFeeds: [...TOP_LEVEL_FEEDS],
  showTopLevelFeedUnreadCounts: true,
};

const STORAGE_PREFIX = "the-social-wire.feed-display.v1";

function isTopLevelFeed(value: unknown): value is TopLevelFeed {
  return (
    typeof value === "string" &&
    (TOP_LEVEL_FEEDS as readonly string[]).includes(value)
  );
}

export function normalizeFeedDisplayPreferences(
  value:
    | Pick<
        PreferencesRecord,
        "visibleFeeds" | "showTopLevelFeedUnreadCounts"
      >
    | FeedDisplayPreferences
    | null
    | undefined,
): FeedDisplayPreferences {
  const visible = Array.from(
    new Set((value?.visibleFeeds ?? []).filter(isTopLevelFeed)),
  );
  return {
    visibleFeeds:
      visible.length > 0
        ? visible
        : [...DEFAULT_FEED_DISPLAY_PREFERENCES.visibleFeeds],
    showTopLevelFeedUnreadCounts:
      value?.showTopLevelFeedUnreadCounts ??
      DEFAULT_FEED_DISPLAY_PREFERENCES.showTopLevelFeedUnreadCounts,
  };
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
