import { describe, expect, it } from "bun:test";

import { resolveReadLaterSaveTarget } from "@/lib/readLaterSaveTarget";

describe("resolveReadLaterSaveTarget", () => {
  it("prefers the encountered HTTPS URL over an entry AT URI", () => {
    const entryId =
      "at://did:plc:author/site.standard.document/abc123";
    expect(
      resolveReadLaterSaveTarget({
        entryId,
        url: "https://example.com/article",
        title: "Article",
      })
    ).toEqual({
      subject: "https://example.com/article",
      title: "Article",
      excerpt: undefined,
    });
  });

  it("falls back to the entry subject when no HTTPS URL is available", () => {
    expect(
      resolveReadLaterSaveTarget({
        entryId: "rss-entry-id",
      })
    ).toEqual({
      subject: "rss-entry-id",
      title: undefined,
      excerpt: undefined,
    });
  });
});
