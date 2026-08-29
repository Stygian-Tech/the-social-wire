import { describe, expect, it, mock } from "bun:test";

import {
  buildOpmlImportReview,
  importOpmlFeedBatch,
  MAX_OPML_OUTLINES,
  parseOpmlFeeds,
} from "@/lib/opmlImport";

describe("OPML import", () => {
  it("parses nested RSS and Atom outlines with labels and category paths", () => {
    const feeds = parseOpmlFeeds(`<?xml version="1.0"?>
      <opml version="2.0">
        <body>
          <outline text="Technology">
            <outline type="rss" text="Example &amp; Friends" xmlUrl="http://EXAMPLE.com/feed.xml" htmlUrl="http://example.com/" />
            <outline type="atom" title="Second Feed" xmlUrl="https://second.example/atom.xml?format=full" />
          </outline>
        </body>
      </opml>`);

    expect(feeds).toEqual([
      {
        feedUrl: "https://example.com/feed.xml",
        title: "Example & Friends",
        htmlUrl: "https://example.com",
        categoryPath: ["Technology"],
        sourceIndex: 0,
      },
      {
        feedUrl: "https://second.example/atom.xml?format=full",
        title: "Second Feed",
        categoryPath: ["Technology"],
        sourceIndex: 1,
      },
    ]);
  });

  it("uses the hostname when the outline has no title or text", () => {
    const [feed] = parseOpmlFeeds(
      `<opml><body><outline xmlUrl="https://news.example/rss" /></body></opml>`
    );
    expect(feed?.title).toBe("news.example");
  });

  it("ignores invalid and blocked URLs while preserving valid document order", () => {
    const feeds = parseOpmlFeeds(`<opml><body>
      <outline text="Container"><outline text="No URL" /></outline>
      <outline text="JavaScript" xmlUrl="javascript:alert(1)" />
      <outline text="Credentials" xmlUrl="https://user:pass@example.com/feed" />
      <outline text="Private" xmlUrl="http://127.0.0.1/feed" />
      <outline text="Valid" xmlUrl="https://valid.example/feed#fragment" />
    </body></opml>`);

    expect(feeds.map((feed) => feed.feedUrl)).toEqual([
      "https://valid.example/feed",
    ]);
  });

  it("rejects malformed XML, non-OPML XML, and a missing body", () => {
    expect(() => parseOpmlFeeds("<opml><body></opml>")).toThrow("not valid XML");
    expect(() => parseOpmlFeeds("<rss />")).toThrow("not an OPML");
    expect(() => parseOpmlFeeds("<opml />")).toThrow("missing its body");
  });

  it("rejects DOCTYPE declarations", () => {
    expect(() =>
      parseOpmlFeeds(
        '<!DOCTYPE opml [<!ENTITY feed "https://example.com/feed">]><opml><body><outline xmlUrl="&feed;" /></body></opml>'
      )
    ).toThrow("DOCTYPE");
  });

  it("returns an empty list for an empty OPML body", () => {
    expect(parseOpmlFeeds("<opml><body /></opml>")).toEqual([]);
  });

  it("rejects excessive outline counts without recursive traversal", () => {
    const outlines = Array.from(
      { length: MAX_OPML_OUTLINES + 1 },
      () => "<outline />"
    ).join("");

    expect(() => parseOpmlFeeds(`<opml><body>${outlines}</body></opml>`)).toThrow(
      `more than ${MAX_OPML_OUTLINES.toLocaleString()} outlines`
    );
  });

  it("dedupes equivalent file entries and marks existing subscriptions", () => {
    const parsed = parseOpmlFeeds(`<opml><body>
      <outline title="First Metadata Wins" xmlUrl="http://Example.com/feed" />
      <outline title="Duplicate" xmlUrl="https://example.com/feed" />
      <outline title="Query A" xmlUrl="https://example.com/feed?view=a" />
      <outline title="Query B" xmlUrl="https://example.com/feed?view=b" />
    </body></opml>`);

    const review = buildOpmlImportReview(parsed, ["HTTP://EXAMPLE.COM/feed"]);

    expect(review.duplicateCount).toBe(1);
    expect(review.candidates.map(({ title, feedUrl, status }) => ({ title, feedUrl, status }))).toEqual([
      {
        title: "First Metadata Wins",
        feedUrl: "https://example.com/feed",
        status: "already-subscribed",
      },
      {
        title: "Query A",
        feedUrl: "https://example.com/feed?view=a",
        status: "available",
      },
      {
        title: "Query B",
        feedUrl: "https://example.com/feed?view=b",
        status: "available",
      },
    ]);
  });

  it("rechecks existing feeds, writes sequentially, and reports partial failures", async () => {
    const feeds = parseOpmlFeeds(`<opml><body>
      <outline title="Existing" xmlUrl="https://existing.example/feed" />
      <outline title="Good" xmlUrl="https://good.example/feed" />
      <outline title="Broken" xmlUrl="https://broken.example/feed" />
    </body></opml>`);
    const writes: string[] = [];
    const progress: string[] = [];
    const createSubscription = mock(async (feed: (typeof feeds)[number]) => {
      writes.push(feed.feedUrl);
      if (feed.feedUrl.includes("broken")) throw new Error("PDS refused the record");
    });

    const result = await importOpmlFeedBatch({
      feeds,
      existingFeedUrls: ["https://existing.example/feed"],
      createSubscription,
      onProgress: ({ status }) => progress.push(status),
    });

    expect(writes).toEqual([
      "https://good.example/feed",
      "https://broken.example/feed",
    ]);
    expect(result.imported.map((feed) => feed.title)).toEqual(["Good"]);
    expect(result.skippedExisting.map((feed) => feed.title)).toEqual(["Existing"]);
    expect(result.failed).toEqual([
      {
        feed: feeds[2],
        message: "PDS refused the record",
      },
    ]);
    expect(progress).toEqual(["already-subscribed", "imported", "failed"]);
  });
});
