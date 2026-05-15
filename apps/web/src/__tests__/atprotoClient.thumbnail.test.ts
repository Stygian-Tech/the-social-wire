import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";
import {
  resolveEntryThumbnailUrl,
  resolveEntryThumbnailUrls,
} from "@/lib/atprotoClient";

describe("resolveEntryThumbnailUrl", () => {
  const originalFetch = globalThis.fetch;

  beforeEach(() => {
    globalThis.fetch = mock(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            service: [
              {
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://pds.test.example",
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    ) as unknown as typeof fetch;
  });

  afterEach(() => {
    globalThis.fetch = originalFetch;
  });

  it("returns HTTPS coverImage string as-is", async () => {
    const url = await resolveEntryThumbnailUrl(
      "at://did:plc:alice/site.standard.document/rkey1",
      { coverImage: "https://cdn.example.com/cover.jpg" },
      undefined
    );
    expect(url).toBe("https://cdn.example.com/cover.jpg");
    expect(globalThis.fetch).not.toHaveBeenCalled();
  });

  it("maps coverImage blob to sync.getBlob using canonical DID on author's PDS", async () => {
    const url = await resolveEntryThumbnailUrl(
      "at://did:plc:alice/site.standard.document/rkey1",
      {
        coverImage: {
          $type: "blob",
          ref: { $link: "bafyreiabc" },
          mimeType: "image/jpeg",
          size: 100,
        },
      },
      undefined
    );
    expect(url).toBe(
      "https://pds.test.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Aalice&cid=bafyreiabc"
    );
  });

  it("falls back to thumbnailUrl when no blob cover", async () => {
    const url = await resolveEntryThumbnailUrl(
      "at://did:plc:bob/site.standard.document/rk",
      { thumbnailUrl: "https://img.example/thumb.png" },
      undefined
    );
    expect(url).toBe("https://img.example/thumb.png");
  });

  it("resolves handle repo segments to DID before plc + getBlob", async () => {
    globalThis.fetch = mock((input: RequestInfo | URL) => {
      const url =
        typeof input === "string" ? input : input instanceof Request ? input.url : input.href;
      if (url.includes("identity.resolveHandle")) {
        return Promise.resolve(
          new Response(JSON.stringify({ did: "did:plc:handleowner" }), {
            status: 200,
            headers: { "Content-Type": "application/json" },
          })
        );
      }
      if (url.includes("plc.directory")) {
        return Promise.resolve(
          new Response(
            JSON.stringify({
              service: [
                {
                  id: "#atproto_pds",
                  type: "AtprotoPersonalDataServer",
                  serviceEndpoint: "https://pds.fromhandle.example",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }
      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;

    const url = await resolveEntryThumbnailUrl(
      "at://alice.example/site.standard.document/rkey1",
      {
        coverImage: {
          $type: "blob",
          ref: { $link: "bafyreixyz" },
          mimeType: "image/jpeg",
          size: 10,
        },
      },
      undefined
    );

    expect(url).toBe(
      "https://pds.fromhandle.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Ahandleowner&cid=bafyreixyz"
    );
  });

  it("omits Bridgy relay sync.getBlob for browser thumbnails (blob-only record)", async () => {
    globalThis.fetch = mock(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            service: [
              {
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "http://atproto.brid.gy/",
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    ) as unknown as typeof fetch;

    const url = await resolveEntryThumbnailUrl(
      "at://did:plc:bridgyrelay/site.standard.document/rk",
      {
        coverImage: {
          $type: "blob",
          ref: { $link: "bafyreiabc" },
          mimeType: "image/jpeg",
          size: 10,
        },
      },
      undefined
    );

    expect(url).toBeUndefined();
  });

  it("prefers HTTPS thumbnail metadata when PLC is Bridgy relay (blob cover + thumbnailUrl)", async () => {
    globalThis.fetch = mock(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            service: [
              {
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "https://atproto.brid.gy/",
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    ) as unknown as typeof fetch;

    const r = await resolveEntryThumbnailUrls(
      "at://did:plc:bridgyrelay/site.standard.document/rk",
      {
        coverImage: {
          $type: "blob",
          ref: { $link: "bafyreiabc" },
          mimeType: "image/jpeg",
          size: 10,
        },
        thumbnailUrl: "https://publisher.example/card.png",
      },
      undefined
    );

    expect(r.thumbnailUrl).toBe("https://publisher.example/card.png");
    expect(r.thumbnailFallbackUrl).toBeUndefined();
  });

  it("uses https PDS origin when plc advertises http (mixed-content safe)", async () => {
    globalThis.fetch = mock(() =>
      Promise.resolve(
        new Response(
          JSON.stringify({
            service: [
              {
                id: "#atproto_pds",
                type: "AtprotoPersonalDataServer",
                serviceEndpoint: "http://pds-plain-http.example/",
              },
            ],
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
      )
    ) as unknown as typeof fetch;

    const url = await resolveEntryThumbnailUrl(
      "at://did:plc:httpthumb/site.standard.document/rk",
      {
        coverImage: {
          $type: "blob",
          ref: { $link: "bafyreiq" },
          mimeType: "image/jpeg",
          size: 10,
        },
      },
      undefined
    );

    expect(url?.startsWith("https://pds-plain-http.example/")).toBe(true);
  });

  it("shares plc.directory lookups for concurrent thumbnails on the same repo", async () => {
    let plcHits = 0;
    globalThis.fetch = mock((input: RequestInfo | URL) => {
      const url =
        typeof input === "string" ? input : input instanceof Request ? input.url : input.href;
      if (url.includes("plc.directory")) {
        plcHits += 1;
        return Promise.resolve(
          new Response(
            JSON.stringify({
              service: [
                {
                  id: "#atproto_pds",
                  type: "AtprotoPersonalDataServer",
                  serviceEndpoint: "https://pds.concurrent.example",
                },
              ],
            }),
            { status: 200, headers: { "Content-Type": "application/json" } }
          )
        );
      }
      return Promise.reject(new Error(`unexpected fetch: ${url}`));
    }) as unknown as typeof fetch;

    await Promise.all([
      resolveEntryThumbnailUrl(
        "at://did:plc:concblob/site.standard.document/a",
        {
          coverImage: {
            $type: "blob",
            ref: { $link: "cid-a" },
            mimeType: "image/jpeg",
            size: 1,
          },
        },
        undefined
      ),
      resolveEntryThumbnailUrl(
        "at://did:plc:concblob/site.standard.entry/b",
        {
          coverImage: {
            $type: "blob",
            ref: { $link: "cid-b" },
            mimeType: "image/jpeg",
            size: 1,
          },
        },
        undefined
      ),
    ]);

    expect(plcHits).toBe(1);
  });

  describe("resolveEntryThumbnailUrls", () => {
    it("provides HTTPS fallback metadata when blob is primary thumbnail", async () => {
      const r = await resolveEntryThumbnailUrls(
        "at://did:plc:bobothumb/site.standard.document/rk",
        {
          coverImage: {
            $type: "blob",
            ref: { $link: "bafyabc" },
            mimeType: "image/jpeg",
            size: 1,
          },
          thumbnailUrl: "https://publisher.example/card.png",
        },
        undefined
      );
      expect(r.thumbnailFallbackUrl).toBe("https://publisher.example/card.png");
      expect(r.thumbnailUrl).toContain("com.atproto.sync.getBlob");
      expect(r.thumbnailUrl).toContain("did%3Aplc%3Abobothumb");
    });
  });
});
