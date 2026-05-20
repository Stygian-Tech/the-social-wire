import { describe, expect, it } from "bun:test";
import { canonicalArticleHttpsUrl } from "@/lib/articleCanonicalUrl";
import type { EntryDetail } from "@/lib/atprotoClient";

function makeEntry(partial: Partial<EntryDetail>): EntryDetail {
  return {
    entryId: "at://did:plc:author/site.standard.document/abc",
    title: "Test",
    summary: null,
    publishedAt: "2026-05-19T12:00:00.000Z",
    authorDid: "did:plc:author",
    authorHandle: "author.test",
    embedUrl: null,
    originalUrl: null,
    thumbnailUrl: null,
    ...partial,
  };
}

describe("articleCanonicalUrl", () => {
  it("prefers embedUrl over originalUrl", () => {
    const url = canonicalArticleHttpsUrl(
      makeEntry({
        embedUrl: "http://example.com/article?bridge_completed=1",
        originalUrl: "https://other.example/post",
      })
    );
    expect(url).toBe("https://example.com/article");
  });

  it("uses originalUrl when embedUrl absent", () => {
    const url = canonicalArticleHttpsUrl(
      makeEntry({ originalUrl: "http://publisher.example/story" })
    );
    expect(url).toBe("https://publisher.example/story");
  });

  it("returns null for non-http URLs", () => {
    expect(
      canonicalArticleHttpsUrl(makeEntry({ originalUrl: "at://did/record" }))
    ).toBeNull();
  });
});
