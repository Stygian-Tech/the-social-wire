import { describe, it, expect, mock, beforeEach, afterEach } from "bun:test";
import { resolveEntryThumbnailUrl } from "@/lib/atprotoClient";

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
    ) as typeof fetch;
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

  it("maps coverImage blob to sync.getBlob on author's PDS", async () => {
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
});
