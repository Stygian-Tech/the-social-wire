import { describe, it, expect } from "bun:test";
import {
  normalizeRssFeedUrlInput,
  validateRssFeedFetchUrl,
  rssPublicationIdFromNormalizedFeedUrl,
  normalizedFeedUrlFromRssPublicationId,
  rssEntryIdFromParts,
  rssEntryIdDecode,
  stableItemKeyFromRssItem,
  dedupeEntryListItems,
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

  it("prefers normalized link over opaque guid for stable keys", () => {
    const key = stableItemKeyFromRssItem({
      guid: "abc",
      link: "http://example.net/article",
    });
    expect(key).toBe("link:https://example.net/article");
  });

  it("dedupes rss entries that share a canonical article link", () => {
    const feed = "https://example.net/feed.xml";
    const linkEntry = {
      entryId: rssEntryIdFromParts(feed, "link:https://example.net/article"),
      title: "Post",
      publishedAt: "2026-01-01T00:00:00.000Z",
    };
    const guidEntry = {
      entryId: rssEntryIdFromParts(feed, "guid:abc"),
      title: "Post",
      summary: "https://example.net/article",
      publishedAt: "2026-01-01T00:00:00.000Z",
    };
    expect(dedupeEntryListItems([linkEntry, guidEntry])).toHaveLength(1);
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
