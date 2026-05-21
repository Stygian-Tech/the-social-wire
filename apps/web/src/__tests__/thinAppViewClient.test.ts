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

  it("getEntryFromAppView fetches entry detail from gateway", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("/v1/appview/entry?");
      expect(url).toContain("entryId=");
      return new Response(
        JSON.stringify({
          entryId: "at://did:plc:alice/site.standard.document/entry1",
          title: "Detail",
          publishedAt: "2024-01-01T00:00:00.000Z",
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
    expect(fetchHandler).toHaveBeenCalledTimes(1);
  });

  it("writeThroughReadMark posts subjectUri and readAt", async () => {
    const fetchHandler = mock(async (url: string, init?: RequestInit) => {
      expect(url).toBe("https://api.example.test/v1/appview/read-marks");
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

  it("fetchAppViewUnreadCounts returns counts map", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("/v1/appview/unread-counts?");
      expect(url).toContain("publicationIds=");
      return new Response(
        JSON.stringify({ counts: { "did:plc:alice": 2 } }),
        { status: 200, headers: { "Content-Type": "application/json" } }
      );
    });

    const { fetchAppViewUnreadCounts } = await import("@/lib/thinAppViewClient");
    const counts = await fetchAppViewUnreadCounts(
      { fetchHandler } as never,
      ["did:plc:alice"]
    );
    expect(counts["did:plc:alice"]).toBe(2);
  });
});
