import { afterEach, beforeEach, describe, expect, it, mock } from "bun:test";

import {
  getWire,
  getWireFeedCatalog,
  getWireItem,
  selectWireLanguage,
  selectWireViewerRegion,
  wireItemToEntryListItem,
  wirePageToEntriesPage,
  wireProvenanceLabel,
  wireReasonLabel,
  type WireItem,
} from "@/lib/wireFeedClient";

const originalFetch = globalThis.fetch;
const originalEnvironment = { ...process.env };

const item: WireItem = {
  itemId: "wire:item:one",
  canonicalUrl: "http://news.example/story",
  representativeUri: "at://did:plc:writer/site.standard.document/story",
  title: "A Story",
  summary: "Summary",
  publishedAt: "2026-08-20T10:00:00.000Z",
  thumbnailUrl: "http://news.example/image.jpg",
  source: {
    name: "Example News",
    domain: "news.example",
    publication: "Example News",
    author: "A. Writer",
  },
  reasons: ["breaking_story", "widely_discussed", "resurfacing"],
  provenance: ["Discussed across three communities"],
};

describe("The Wire client", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
    process.env = { ...originalEnvironment };
  });

  it("uses the public catalog and The Wire XRPC endpoints without credentials", async () => {
    const requests: Array<{ url: string; init?: RequestInit }> = [];
    globalThis.fetch = mock(async (url: string, init?: RequestInit) => {
      requests.push({ url, init });
      if (url.includes("getFeedCatalog")) {
        return Response.json({
          enabled: true,
          available: true,
          title: "The Wire",
          subtitle: "Important stories across the social web",
          supportedLanguages: ["en", "es"],
        });
      }
      if (url.includes("getWireItem")) return Response.json({ item });
      return Response.json({
        generationId: "generation-1",
        generatedAt: "2026-08-20T12:00:00.000Z",
        language: "en",
        cursor: "next",
        source: "ranked",
        degraded: false,
        items: [item],
      });
    }) as unknown as typeof fetch;

    await getWireFeedCatalog();
    const page = await getWire({ language: "en", cursor: "cursor-1", limit: 25 });
    const detail = await getWireItem(item.itemId);

    expect(page.items[0]?.itemId).toBe(item.itemId);
    expect(detail?.item.canonicalUrl).toBe(item.canonicalUrl);
    expect(requests.map(({ url }) => url)).toEqual([
      "https://api.example.test/xrpc/app.thesocialwire.discovery.getFeedCatalog",
      "https://api.example.test/xrpc/app.thesocialwire.discovery.getWire?cursor=cursor-1&lang=en&limit=25",
      "https://api.example.test/xrpc/app.thesocialwire.discovery.getWireItem?itemId=wire%3Aitem%3Aone",
    ]);
    expect(requests.every(({ init }) => init?.credentials === "omit")).toBe(true);
  });

  it("sends the dedicated moderation proof pool on authenticated The Wire requests", async () => {
    const proofPool = "preferences,blocks,mutes,list-mutes,list-blocks";
    let pdsNonce = 0;
    const pdsFetchHandler = mock(async () =>
      new Response(null, {
        status: 200,
        headers: { "DPoP-Nonce": `nonce-${++pdsNonce}` },
      }),
    );
    const fetchMock = mock(async (url: string, init?: RequestInit) => {
      expect(url).toStartWith(
        "https://api.example.test/xrpc/app.thesocialwire.discovery.getWire",
      );
      const headers = new Headers(init?.headers);
      if (url.includes("getWireItem")) {
        expect(headers.get("X-Wire-Moderation-DPoP")?.split(",")).toHaveLength(
          5,
        );
        return Response.json({ item });
      }
      expect(headers.get("X-Wire-Moderation-DPoP")).toBe(proofPool);
      return Response.json({
        generationId: "generation-viewer",
        generatedAt: "2026-08-20T12:00:00.000Z",
        language: "en",
        source: "ranked",
        degraded: false,
        items: [],
      });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    const oauthSession = {
      did: "did:plc:viewer",
      getTokenSet: async () => ({
        access_token: "access-token",
        token_type: "DPoP",
      }),
      getTokenInfo: async () => ({
        aud: "https://pds.example",
        sub: "did:plc:viewer",
      }),
      fetchHandler: pdsFetchHandler,
      server: {
        dpopKey: {
          bareJwk: { kty: "EC", crv: "P-256", x: "x", y: "y" },
          algorithms: ["ES256"],
          createJwt: async () => "dpop-proof",
        },
        dpopNonces: {
          get: async () => undefined,
          set: async () => undefined,
        },
        serverMetadata: {
          dpop_signing_alg_values_supported: ["ES256"],
        },
      },
    } as never;

    const page = await getWire({
      language: "en",
      oauthSession,
      moderationDpopProofPool: proofPool,
    });
    const detail = await getWireItem(item.itemId, {
      oauthSession,
    });

    expect(page.generationId).toBe("generation-viewer");
    expect(detail?.item.itemId).toBe(item.itemId);
    expect(pdsFetchHandler).toHaveBeenCalledTimes(5);
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("maps canonical URLs, representative social subjects, and bounded known reasons", () => {
    const entry = wireItemToEntryListItem(
      { ...item, reasons: ["breaking_story", "unknown", "widely_discussed"] },
      "2026-08-20T12:00:00.000Z",
    );

    expect(entry.entryId).toBe(item.representativeUri!);
    expect(entry.originalUrl).toBe("https://news.example/story");
    expect(entry.thumbnailUrl).toBe("https://news.example/image.jpg");
    expect(entry.wireItem?.itemId).toBe(item.itemId);
    // Unknown values never become UI copy and at most two known reasons survive.
    expect(entry.wireItem?.reasons).toEqual([
      "breaking_story",
      "widely_discussed",
    ]);
    expect(wireReasonLabel("unknown")).toBeNull();
    expect(wireProvenanceLabel("standard_site")).toBe(
      "Published on Standard.site",
    );
    expect(wireProvenanceLabel("unknown")).toBeNull();
  });

  it("preserves server rank order and degraded generation evidence", () => {
    const page = wirePageToEntriesPage({
      generationId: "generation-stale",
      generatedAt: "2026-08-20T12:00:00.000Z",
      language: "en",
      source: "stale_generation",
      degraded: true,
      items: [item, { ...item, itemId: "wire:item:two", title: "Second" }],
    });

    expect(page.entries.map((entry) => entry.wireItem?.itemId)).toEqual([
      "wire:item:one",
      "wire:item:two",
    ]);
    expect(page.source).toBe("stale_generation");
    expect(page.degraded).toBe(true);
  });

  it("selects an exact or base language supported by the catalog", () => {
    expect(selectWireLanguage(["en", "fr"], ["fr-CA", "en-US"])).toBe("fr");
    expect(selectWireLanguage(["en-US", "es"], ["en-GB"])).toBe("en-US");
  });

  it("uses the global Wire when the user's language is not advertised", () => {
    expect(selectWireLanguage(["en", "fr"], ["es-MX"])).toBeUndefined();
    expect(selectWireLanguage([], ["de-DE"])).toBeUndefined();
  });

  it("falls back safely when no valid user language is available", () => {
    expect(selectWireLanguage(["en", "fr"], ["", "1234"])).toBeUndefined();
    expect(selectWireLanguage([], [])).toBeUndefined();
  });

  it("sends only a coarse US relevance region from the browser locale", () => {
    expect(selectWireViewerRegion(["en-US"])).toBeUndefined();
    expect(selectWireViewerRegion(["en-GB"])).toBe("outside-us");
    expect(selectWireViewerRegion(["zh-Hant-TW"])).toBe("outside-us");
    expect(selectWireViewerRegion(["en"])).toBeUndefined();
    expect(selectWireViewerRegion(["1234-GB"])).toBeUndefined();
  });
});
