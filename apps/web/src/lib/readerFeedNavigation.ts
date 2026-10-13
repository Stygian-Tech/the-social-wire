import type { ReaderFeedSelection } from "@/lib/readerFeedSelectionStorage";

/** The /read index owns feed selection on the client; other reader paths need a route transition. */
export function navigateReaderFeed(
  pathname: string,
  feed: ReaderFeedSelection,
  pushRoute: (href: string) => void,
) {
  const href = `/read?feed=${feed}`;
  if (pathname === "/read") {
    // Next preserves its history state and synchronizes useSearchParams, including back/forward.
    window.history.pushState(null, "", href);
    return;
  }
  pushRoute(href);
}
