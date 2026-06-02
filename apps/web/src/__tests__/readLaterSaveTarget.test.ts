import { describe, expect, it } from "bun:test";

import { resolveReadLaterSaveTarget } from "@/lib/readLaterSaveTarget";

describe("resolveReadLaterSaveTarget", () => {
  it("prefers native subject saves for standard.site entry AT-URIs", () => {
    const entryId =
      "at://did:plc:author/site.standard.document/abc123";
    expect(
      resolveReadLaterSaveTarget({
        entryId,
        url: "https://example.com/article",
        title: "Article",
      })
    ).toEqual({
      kind: "native",
      subjectUri: entryId,
      linkedWebUrl: "https://example.com/article",
      title: "Article",
      excerpt: undefined,
    });
  });

  it("uses external saves for plain HTTPS URLs without native entry ids", () => {
    expect(
      resolveReadLaterSaveTarget({
        entryId: "rss-entry-id",
        url: "https://example.com/article",
      })
    ).toEqual({
      kind: "external",
      url: "https://example.com/article",
      title: undefined,
      excerpt: undefined,
    });
  });
});
