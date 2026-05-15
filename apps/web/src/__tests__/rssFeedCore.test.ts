import { describe, it, expect } from "bun:test";
import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
  rssPublicationIdFromNormalizedFeedUrl,
  normalizedFeedUrlFromRssPublicationId,
  rssEntryIdFromParts,
  rssEntryIdDecode,
  stableItemKeyFromRssItem,
} from "@/lib/rssFeedCore";

describe("rssFeedCore", () => {
  it("normalizes RSS URL to HTTPS", () => {
    expect(normalizeRssFeedUrlInput("http://example.com/feed.xml")).toBe(
      "https://example.com/feed.xml"
    );
  });

  it("rejects loopback URLs for fetch", () => {
    expect(validateRssFeedFetchUrl("http://127.0.0.1/feed.xml").ok).toBe(false);
  });

  it("accepts ordinary public hosts", () => {
    expect(validateRssFeedFetchUrl("https://example.com/rss").ok).toBe(true);
  });

  it("round-trips rss publication ids", () => {
    const u = "https://example.org/feed";
    const id = rssPublicationIdFromNormalizedFeedUrl(u);
    expect(id.startsWith("rss:")).toBe(true);
    expect(normalizedFeedUrlFromRssPublicationId(id)).toBe(u);
  });

  it("round-trips rss entry ids via stable keys", () => {
    const feed = "https://example.net/feed.xml";
    const key = stableItemKeyFromRssItem({
      guid: undefined,
      link: "https://example.net/article",
    });
    const eid = rssEntryIdFromParts(feed, key);
    const dec = rssEntryIdDecode(eid);
    expect(dec).toEqual({ feedUrl: feed, itemKey: key });
  });
});
