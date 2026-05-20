import { describe, expect, it, mock, beforeEach, afterEach } from "bun:test";
import { resetAtprotoClientCachesForTests } from "@/lib/atprotoClient";

const ORIG_ENV = { ...process.env };
const ORIG_FETCH = globalThis.fetch;

describe("thinAppViewClient", () => {
  beforeEach(() => {
    resetAtprotoClientCachesForTests();
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "true";
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL = "https://api.example.test";
    globalThis.fetch = mock((input: RequestInfo | URL) => {
      const url =
        typeof input === "string"
          ? input
          : input instanceof Request
            ? input.url
            : input.href;
      if (url.includes("plc.directory")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              service: [
                {
                  id: "#atproto_pds",
                  type: "AtprotoPersonalDataServer",
                  serviceEndpoint: "https://pds.example.test",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }
      if (url.includes("com.atproto.repo.getRecord")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              value: {
                $type: "site.standard.publication",
                name: "Example Pub",
                url: "https://example.offprint.app",
              },
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }
      if (url.includes("com.atproto.repo.listRecords")) {
        return Promise.resolve(
          new Response(JSON.stringify({ records: [] }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          })
        );
      }
      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;
  });

  afterEach(() => {
    process.env = { ...ORIG_ENV };
    globalThis.fetch = ORIG_FETCH;
    resetAtprotoClientCachesForTests();
    mock.restore();
  });

  it("isThinAppViewEnabled reflects NEXT_PUBLIC_USE_THIN_APPVIEW", async () => {
    const { isThinAppViewEnabled } = await import("@/lib/thinAppViewClient");
    expect(isThinAppViewEnabled()).toBe(true);
    process.env.NEXT_PUBLIC_USE_THIN_APPVIEW = "false";
    expect(isThinAppViewEnabled()).toBe(false);
  });

  it("listEntriesFromAppView calls gateway with author and publication params", async () => {
    const fetchHandler = mock(async (url: string) => {
      expect(url).toContain("https://api.example.test/v1/appview/entries");
      expect(url).toContain("authorDid=did%3Aplc%3Aalice");
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
      filter: "unread",
      oauthSession: { fetchHandler } as never,
    });

    expect(page.entries).toHaveLength(1);
    expect(page.entries[0]?.title).toBe("Indexed");
    expect(page.cursor).toBe("next-cursor");
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
});
