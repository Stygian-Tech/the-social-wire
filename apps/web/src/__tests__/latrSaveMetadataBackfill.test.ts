import { afterEach, describe, expect, it, mock } from "bun:test";

import {
  backfillUrlForLatrSave,
  fetchLatrOgPreview,
  isLatrSaveMetadataSparse,
  isWeakLatrSaveTitle,
  mergeLatrExternalSubjectPreview,
  mergeLatrSaveBackfillMetadata,
  needsLatrSaveOgBackfill,
  resetLatrOgPreviewAuthRejectedForTests,
} from "@/lib/latrSaveMetadataBackfill";
import type { MergedLatrSave } from "@/lib/pdsClient";

const ORIG_FETCH = globalThis.fetch;
const ORIG_LOCATION_DESCRIPTOR = Object.getOwnPropertyDescriptor(
  globalThis,
  "location"
);

afterEach(() => {
  resetLatrOgPreviewAuthRejectedForTests();
  globalThis.fetch = ORIG_FETCH;
  if (ORIG_LOCATION_DESCRIPTOR) {
    Object.defineProperty(globalThis, "location", ORIG_LOCATION_DESCRIPTOR);
  } else {
    delete (globalThis as { location?: Location }).location;
  }
});

describe("latrSaveMetadataBackfill", () => {
  const externalRow: MergedLatrSave = {
    kind: "external",
    normalizedUrl: "https://example.com/article",
    url: "https://example.com/article",
    savedAt: "2026-06-01T12:00:00.000Z",
    externalRkey: "EXT",
    itemRkey: "ITEM",
    externalUri: "at://did/com.latr.saved.external/EXT",
    itemUri: "at://did/com.latr.saved.item/ITEM",
    subjectUri: "at://did/com.latr.saved.external/EXT",
  };

  it("detects sparse external rows missing image and title", () => {
    expect(isLatrSaveMetadataSparse(externalRow)).toBe(true);
    expect(needsLatrSaveOgBackfill(externalRow)).toBe(true);
  });

  it("detects hostname-only titles as sparse", () => {
    expect(
      isLatrSaveMetadataSparse({
        ...externalRow,
        title: "example.com",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(true);
  });

  it("detects site-label titles as weak", () => {
    const url = "https://www.nytimes.com/2026/05/31/us/politics/story.html";
    expect(
      isWeakLatrSaveTitle("The New York Times", "The New York Times", url)
    ).toBe(true);
    expect(
      needsLatrSaveOgBackfill({
        ...externalRow,
        url,
        normalizedUrl: url,
        title: "The New York Times",
        site: "The New York Times",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(true);
  });

  it("backfills rows that have title and image but are missing text metadata", () => {
    expect(
      isLatrSaveMetadataSparse({
        ...externalRow,
        title: "Example Article",
        image: "https://example.com/thumb.jpg",
      })
    ).toBe(true);
  });

  it("treats rows with full display metadata as complete", () => {
    expect(
      isLatrSaveMetadataSparse({
        ...externalRow,
        title: "Example Article",
        image: "https://example.com/thumb.jpg",
        excerpt: "Summary",
        site: "Example",
        author: "Jane",
      })
    ).toBe(false);
  });

  it("still backfills missing NYT thumbnails when title looks complete", () => {
    expect(
      needsLatrSaveOgBackfill({
        ...externalRow,
        title: "Trump and Iran Stalemate",
        linkedWebUrl: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
        url: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
        normalizedUrl: "https://www.nytimes.com/2026/05/31/us/politics/story.html",
      })
    ).toBe(true);
  });

  it("resolves backfill URL for external and native rows", () => {
    expect(backfillUrlForLatrSave(externalRow)).toBe("https://example.com/article");

    const nativeRow: MergedLatrSave = {
      kind: "native",
      savedAt: "2026-06-01T12:00:00.000Z",
      itemRkey: "ITEM2",
      itemUri: "at://did/com.latr.saved.item/ITEM2",
      subjectUri: "at://did/app/site.standard.document/abc",
      linkedWebUrl: "https://news.example/story",
    };
    expect(backfillUrlForLatrSave(nativeRow)).toBe("https://news.example/story");
  });

  it("replaces weak titles from OG backfill but keeps strong titles", () => {
    const url = "https://www.nytimes.com/2026/05/31/us/politics/story.html";
    const weakMerged = mergeLatrSaveBackfillMetadata(
      {
        ...externalRow,
        url,
        normalizedUrl: url,
        title: "The New York Times",
        site: "The New York Times",
      },
      {
        title: "Trump and Iran Stalemate",
        image: "https://static01.nyt.com/thumb.jpg",
      }
    );
    expect(weakMerged.title).toBe("Trump and Iran Stalemate");
    expect(weakMerged.image).toBe("https://static01.nyt.com/thumb.jpg");

    const strongMerged = mergeLatrSaveBackfillMetadata(
      {
        ...externalRow,
        title: "Already Good Headline",
      },
      {
        title: "OG Title Should Not Win",
        image: "https://cdn.example/thumb.jpg",
      }
    );
    expect(strongMerged.title).toBe("Already Good Headline");
    expect(strongMerged.image).toBe("https://cdn.example/thumb.jpg");
  });

  it("merges preview fields without clobbering existing metadata", () => {
    const merged = mergeLatrSaveBackfillMetadata(
      { ...externalRow, title: "Kept title", image: "https://existing/thumb.jpg" },
      {
        title: "Preview title",
        excerpt: "Preview excerpt",
        image: "https://cdn.example/thumb.jpg",
        site: "Example",
      }
    );

    expect(merged.title).toBe("Kept title");
    expect(merged.excerpt).toBe("Preview excerpt");
    expect(merged.image).toBe("https://existing/thumb.jpg");
    expect(merged.site).toBe("Example");
  });

  it("hydrates sparse gateway items from their enriched external wrapper", () => {
    const merged = mergeLatrExternalSubjectPreview(
      {
        ...externalRow,
        normalizedUrl: externalRow.subjectUri,
        url: externalRow.subjectUri,
      },
      {
        url: "https://example.com/article?utm_source=reader",
        normalizedUrl: "https://example.com/article",
        title: "Canonical wrapper title",
        excerpt: "Persisted on-protocol excerpt",
        image: "https://cdn.example/article.jpg",
        site: "Example",
        author: "Ada",
      }
    );

    expect(merged.kind).toBe("external");
    if (merged.kind !== "external") throw new Error("Expected external row");
    expect(merged.url).toBe(
      "https://example.com/article?utm_source=reader"
    );
    expect(merged.normalizedUrl).toBe("https://example.com/article");
    expect(merged.linkedWebUrl).toBe("https://example.com/article");
    expect(merged.title).toBe("Canonical wrapper title");
    expect(merged.image).toBe("https://cdn.example/article.jpg");
  });

  it("skips later OG preview requests after the gateway rejects auth", async () => {
    Object.defineProperty(globalThis, "location", {
      configurable: true,
      value: new URL("https://testing.thesocialwire.app/saved"),
    });

    let gatewayCalls = 0;
    const fetchMock = mock(async (url: string) => {
      if (url.startsWith("https://jellybaby.us-east.host.bsky.network/xrpc/")) {
        return new Response(JSON.stringify({ records: [] }), {
          status: 200,
          headers: { "DPoP-Nonce": "pds-nonce" },
        });
      }
      gatewayCalls += 1;
      return new Response(
        JSON.stringify({
          error: "invalid_token",
          message: "Access token signature could not be verified for this route",
        }),
        { status: 401 }
      );
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({
        aud: "https://jellybaby.us-east.host.bsky.network",
      }),
      fetchHandler: fetchMock as unknown as typeof fetch,
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "dpop-proof",
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => {},
        },
        serverMetadata: { dpop_signing_alg_values_supported: ["ES256"] },
      },
    } as never;

    expect(
      await fetchLatrOgPreview(oauthSession, "https://example.com/a")
    ).toBeNull();
    expect(
      await fetchLatrOgPreview(oauthSession, "https://example.com/b")
    ).toBeNull();
    expect(gatewayCalls).toBe(1);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
