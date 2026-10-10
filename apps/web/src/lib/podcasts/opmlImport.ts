import { buildOpmlImportReview, normalizeOpmlFeedUrl, type ParsedOpmlFeed, type OpmlImportBatchResult, type OpmlImportProgress } from "@/lib/opmlImport";
import type { PodcastShow } from "./client";

/** OPML is format-agnostic; the user explicitly chooses the podcast destination. */
export async function importOpmlPodcasts(input: {
  feeds: readonly ParsedOpmlFeed[];
  privateFeeds: boolean;
  existingShows: readonly PodcastShow[];
  assertViewer: () => void;
  resolve: (url: string, privateFeed: boolean) => Promise<PodcastShow>;
  subscribe: (show: PodcastShow) => Promise<void>;
  onProgress?: (progress: OpmlImportProgress) => void;
}): Promise<OpmlImportBatchResult> {
  const result: OpmlImportBatchResult = { imported: [], skippedExisting: [], failed: [] };
  const existingIds = new Set(input.existingShows.map((show) => show.id));
  const existingUrls = new Set(input.existingShows.flatMap((show) => {
    if ((show.visibility === "private" || show.sourceKind === "private-rss") !== input.privateFeeds) return [];
    const url = show.feedUrl && normalizeOpmlFeedUrl(show.feedUrl);
    return url ? [url] : [];
  }));
  const feeds = buildOpmlImportReview(input.feeds, []).candidates;
  for (const [index, feed] of feeds.entries()) {
    // Stop the batch when the account changes, before resolving or writing another feed.
    input.assertViewer();
    let status: OpmlImportProgress["status"];
    try {
      if (existingUrls.has(feed.feedUrl)) {
        result.skippedExisting.push(feed);
        status = "already-subscribed";
      } else {
        const show = await input.resolve(feed.feedUrl, input.privateFeeds);
        input.assertViewer();
        if (existingIds.has(show.id)) {
          result.skippedExisting.push(feed);
          status = "already-subscribed";
        } else {
          // Private resolution subscribes on the private RSS service; public shows use PDS writes.
          if (!input.privateFeeds) await input.subscribe(show);
          input.assertViewer();
          existingIds.add(show.id);
          result.imported.push(feed);
          status = "imported";
        }
        existingUrls.add(feed.feedUrl);
      }
    } catch {
      input.assertViewer();
      result.failed.push({ feed, message: "Could Not Import This Podcast. Retry This Feed." });
      status = "failed";
    }
    input.onProgress?.({ completed: index + 1, total: feeds.length, feed, status });
  }
  return result;
}
