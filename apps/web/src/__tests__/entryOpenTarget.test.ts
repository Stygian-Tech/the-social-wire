import { describe, expect, it } from "bun:test";

import { entryOpenTarget } from "@/lib/entryOpenTarget";

describe("entryOpenTarget", () => {
  it("opens standard.site articles externally", () => {
    expect(
      entryOpenTarget({
        entryId: "at://did:plc:author/site.standard.document/article",
        originalUrl: "https://example.com/article",
      }),
    ).toEqual({
      kind: "external",
      url: "https://example.com/article",
    });
  });

  it("opens Skyreader RSS articles in the native reader", () => {
    expect(
      entryOpenTarget({
        entryId: "rssentry:article",
        originalUrl: "https://example.com/rss-article",
      }),
    ).toEqual({
      kind: "rssReader",
      url: "https://example.com/rss-article",
    });
  });

  it("opens Skyreader RSS articles on the original site when preferred", () => {
    expect(
      entryOpenTarget(
        {
          entryId: "rssentry:article",
          originalUrl: "https://example.com/rss-article",
        },
        "original",
      ),
    ).toEqual({
      kind: "external",
      url: "https://example.com/rss-article",
    });
  });

  it("resolves local mock articles against the current origin", () => {
    expect(
      entryOpenTarget({
        entryId: "rssentry:local",
        originalUrl: "/mock-reader/article.html",
      }),
    ).toEqual({
      kind: "rssReader",
      url: "http://localhost/mock-reader/article.html",
    });
  });

  it("rejects missing, invalid, and non-http article URLs", () => {
    expect(
      entryOpenTarget({
        entryId: "rssentry:missing",
      }),
    ).toBeNull();
    expect(
      entryOpenTarget({
        entryId: "rssentry:invalid",
        originalUrl: "not a URL",
      }),
    ).toBeNull();
    expect(
      entryOpenTarget({
        entryId: "rssentry:script",
        originalUrl: "javascript:alert(1)",
      }),
    ).toBeNull();
  });
});
