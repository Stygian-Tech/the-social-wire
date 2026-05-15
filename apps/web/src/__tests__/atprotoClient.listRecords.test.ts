import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";
import { listEntries } from "@/lib/atprotoClient";

describe("listRecordsOnAuthorRepo via listEntries", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
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
                  serviceEndpoint: "https://atproto.brid.gy",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      if (url.includes("atproto.brid.gy") && url.includes("listRecords")) {
        const sp = new URL(url).searchParams;
        expect(sp.get("reverse")).toBe("false");
        const older =
          "at://did:plc:relay/site.standard.document/3lzdeadbeefaaa";
        const newer =
          "at://did:plc:relay/site.standard.document/3lzdeadbeefbbb";
        return Promise.resolve(
          new Response(
            JSON.stringify({
              records: [
                {
                  uri: older,
                  cid: "c-old",
                  value: {
                    $type: "site.standard.document",
                    title: "Older",
                    publishedAt: "2024-01-01T00:00:00.000Z",
                  },
                },
                {
                  uri: newer,
                  cid: "c-new",
                  value: {
                    $type: "site.standard.document",
                    title: "Newer",
                    publishedAt: "2025-06-01T00:00:00.000Z",
                  },
                },
              ],
              cursor: undefined,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("omits reverse=true on brid.gy PDS and sorts the page newest-first", async () => {
    const { entries } = await listEntries(
      "did:plc:relay",
      undefined,
      50,
      undefined,
      {}
    );
    expect(entries).toHaveLength(2);
    expect(entries[0].title).toBe("Newer");
    expect(entries[1].title).toBe("Older");
  });
});

describe("listEntries cursor chain (relay-style PDS)", () => {
  const originalFetch = globalThis.fetch;

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("follows listRecords cursors across empty pages before returning rows", async () => {
    let listCalls = 0;
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
                  serviceEndpoint: "https://pds.emptychain.brid.gy",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      if (url.includes("pds.emptychain.brid.gy") && url.includes("listRecords")) {
        const sp = new URL(url).searchParams;
        expect(sp.get("reverse")).toBe("false");
        listCalls++;
        if (listCalls === 1) {
          expect(sp.get("cursor")).toBe(null);
          return Promise.resolve(
            new Response(
              JSON.stringify({ records: [], cursor: "gap-page" }),
              { status: 200, headers: { "Content-Type": "application/json" } }
            )
          );
        }
        expect(sp.get("cursor")).toBe("gap-page");
        return Promise.resolve(
          new Response(
            JSON.stringify({
              records: [
                {
                  uri: "at://did:plc:gapped/site.standard.document/first",
                  cid: "c1",
                  value: {
                    $type: "site.standard.document",
                    title: "After gap",
                    publishedAt: "2025-01-01T00:00:00.000Z",
                  },
                },
              ],
              cursor: undefined,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;

    const { entries, cursor } = await listEntries(
      "did:plc:gapped",
      undefined,
      50,
      undefined,
      {}
    );

    expect(listCalls).toBe(2);
    expect(entries).toHaveLength(1);
    expect(entries[0].title).toBe("After gap");
    expect(cursor).toBe("1:");
  });
});

describe("listRecords full PDS host", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
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
                  serviceEndpoint: "https://pds.full.example",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      if (url.includes("pds.full.example") && url.includes("listRecords")) {
        const sp = new URL(url).searchParams;
        expect(sp.get("reverse")).toBe("true");
        return Promise.resolve(
          new Response(
            JSON.stringify({
              records: [
                {
                  uri: "at://did:plc:full/site.standard.document/a",
                  cid: "c1",
                  value: {
                    $type: "site.standard.document",
                    title: "Only",
                    publishedAt: "2025-01-01T00:00:00.000Z",
                  },
                },
              ],
              cursor: undefined,
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }

      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("still sends reverse=true when the PDS is not a brid.gy relay host", async () => {
    const { entries } = await listEntries(
      "did:plc:full",
      undefined,
      50,
      undefined,
      {}
    );
    expect(entries).toHaveLength(1);
    expect(entries[0].title).toBe("Only");
  });
});
