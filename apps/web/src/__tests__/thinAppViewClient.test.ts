import { describe, expect, it, mock, beforeEach, afterEach } from "bun:test";

const ORIG_ENV = { ...process.env };
const ORIG_FETCH = globalThis.fetch;

describe("thinAppViewClient", () => {
  beforeEach(() => {
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
    globalThis.fetch = ORIG_FETCH;
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
    globalThis.fetch = ORIG_FETCH;
    mock.restore();
  });

  it("isThinAppViewEnabled is true by default", async () => {
    delete process.env.NEXT_PUBLIC_USE_THIN_APPVIEW;
    const { isThinAppViewEnabled } = await import("@/lib/thinAppViewClient");
    expect(isThinAppViewEnabled()).toBe(true);
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "false";
    expect(isThinAppViewEnabled()).toBe(false);
  });

  it("listEntriesFromAppView requires appViewScope and sends scope params", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("publicationScopeAtUris=");
      expect(url).toContain("publicationSiteUrls=");
      expect(url).toContain("filter=unread");
      return new Response(
        JSON.stringify({
          entries: [
            {
              entryId: "at://did:plc:alice/site.standard.entry/rkey1",
              title: "Indexed",
              publishedAt: "2024-01-01T00:00:00.000Z",
            },
          ],
          cursor: "next-cursor",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { listEntriesFromAppView } = await import("@/lib/thinAppViewClient");
    const page = await listEntriesFromAppView({
      publicationKey: "at://did:plc:alice/site.standard.publication/main",
      appViewScope: {
        authorDid: "did:plc:alice",
        publicationAtUri: "at://did:plc:alice/site.standard.publication/main",
        publicationScopeAtUris: [
          "at://did:plc:alice/com.standard.publication/main",
        ],
        publicationSiteUrls: ["https://example.offprint.app"],
      },
      filter: "unread",
      oauthSession: { fetchHandler } as never,
    });

    expect(page.entries).toHaveLength(1);
    expect(page.entries[0]?.title).toBe("Indexed");
    expect(page.cursor).toBe("next-cursor");
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("listEntriesFromAppView sends maxEntries instead of cursor", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("maxEntries=120");
      expect(url).not.toContain("cursor=");
      return new Response(
        JSON.stringify({ entries: [], cursor: "more" }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { listEntriesFromAppView } = await import("@/lib/thinAppViewClient");
    await listEntriesFromAppView({
      publicationKey: "at://did:plc:alice/site.standard.publication/main",
      appViewScope: {
        authorDid: "did:plc:alice",
        publicationAtUri: "at://did:plc:alice/site.standard.publication/main",
        publicationScopeAtUris: [],
        publicationSiteUrls: [],
      },
      maxEntries: 120,
      oauthSession: { fetchHandler } as never,
    });
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("normalizes numeric Swift dates returned by the aggregate feed", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("/xrpc/app.thesocialwire.appview.getFeed?");
      return new Response(
        JSON.stringify({
          entries: [
            {
              entryId: "at://did:plc:alice/site.standard.document/entry1",
              title: "Indexed",
              publishedAt: 725_760_000,
              isRead: false,
            },
          ],
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { listAggregateFeedFromAppView } = await import(
      "@/lib/thinAppViewClient"
    );
    const page = await listAggregateFeedFromAppView({
      feed: { kind: "subscribed" },
      oauthSession: { fetchHandler } as never,
    });

    expect(page.entries[0]?.publishedAt).toBe("2024-01-01T00:00:00.000Z");
  });

  it("getEntryFromAppView fetches entry detail from gateway", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("/xrpc/app.thesocialwire.appview.getEntry?");
      expect(url).toContain("entryId=");
      return new Response(
        JSON.stringify({
          entryId: "at://did:plc:alice/site.standard.document/entry1",
          title: "Detail",
          summary: "Detail summary",
          publishedAt: "2024-01-01T00:00:00.000Z",
          thumbnailUrl: "https://cdn.example/detail.jpg",
          thumbnailFallbackUrl: "https://cdn.example/detail-fallback.jpg",
          contentHtml: "<p>Hi</p>",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { getEntryFromAppView } = await import("@/lib/thinAppViewClient");
    const entry = await getEntryFromAppView(
      { fetchHandler } as never,
      "at://did:plc:alice/site.standard.document/entry1"
    );
    expect(entry?.title).toBe("Detail");
    expect(entry?.summary).toBe("Detail summary");
    expect(entry?.thumbnailUrl).toBe("https://cdn.example/detail.jpg");
    expect(entry?.thumbnailFallbackUrl).toBe(
      "https://cdn.example/detail-fallback.jpg"
    );
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("writeThroughReadMark posts subjectUri and readAt", async () => {
    const fetchHandler = mock(async (url: string, init?: RequestInit) => {
      expect(url).toBe(
        "https://api.example.test/xrpc/app.thesocialwire.appview.putReadMark"
      );
      expect(init?.method).toBe("POST");
      const body = JSON.parse(String(init?.body));
      expect(body.subjectUri).toBe("at://did:plc:alice/site.standard.entry/rkey1");
      expect(body.readAt).toBe("2024-06-01T12:00:00.000Z");
      return new Response(null, { status: 200 });
    });

    const { writeThroughReadMark } = await import("@/lib/thinAppViewClient");
    await writeThroughReadMark(
      { fetchHandler } as never,
      "at://did:plc:alice/site.standard.entry/rkey1",
      "2024-06-01T12:00:00.000Z"
    );
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("fetchAppViewUnreadCounts returns count snapshot metadata", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain(
        "/xrpc/app.thesocialwire.appview.getUnreadCounts?"
      );
      expect(url).toContain("publicationIds=");
      return new Response(
        JSON.stringify({
          counts: { "did:plc:alice": 2 },
          generation: 42,
          accuracy: "exact",
          countedAt: "2026-01-01T00:00:00.000Z",
        }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { fetchAppViewUnreadCounts } = await import("@/lib/thinAppViewClient");
    const snapshot = await fetchAppViewUnreadCounts(
      { fetchHandler } as never,
      ["did:plc:alice"]
    );
    expect(snapshot.counts["did:plc:alice"]).toBe(2);
    expect(snapshot.generation).toBe(42);
    expect(snapshot.accuracy).toBe("exact");
  });
});
