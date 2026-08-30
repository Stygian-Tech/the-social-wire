export type ReaderFeedSelection =
  | "wire"
  | "circle"
  | "subscribed"
  | "following";

export function isReaderFeedSelection(
  value: string | null,
): value is ReaderFeedSelection {
  return (
    value === "wire" ||
    value === "circle" ||
    value === "subscribed" ||
    value === "following"
  );
}

export const READER_FEED_SELECTION_STORAGE_KEY =
  "the-social-wire.reader-feed-selection.v1";
const LEGACY_PUBLICATION_TAB_STORAGE_KEY =
  "the-social-wire.sidebar-publication-tab.v1";

export function loadReaderFeedSelection(
  storage: Pick<Storage, "getItem">,
): ReaderFeedSelection | null {
  try {
    const value = storage.getItem(READER_FEED_SELECTION_STORAGE_KEY);
    if (isReaderFeedSelection(value)) {
      return value;
    }
    const legacy = storage.getItem(LEGACY_PUBLICATION_TAB_STORAGE_KEY);
    return legacy === "subscribed" || legacy === "following" ? legacy : null;
  } catch {
    return null;
  }
}

export function saveReaderFeedSelection(
  storage: Pick<Storage, "setItem">,
  feed: ReaderFeedSelection,
): void {
  try {
    storage.setItem(READER_FEED_SELECTION_STORAGE_KEY, feed);
  } catch {
    // Private browsing and quota failures must not block reader navigation.
  }
}
