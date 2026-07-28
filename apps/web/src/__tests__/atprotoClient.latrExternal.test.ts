import { afterEach, describe, expect, it, mock } from "bun:test";

import {
  resetAtprotoClientCachesForTests,
  resolveLatrExternalSavedSubjectPreview,
} from "@/lib/atprotoClient";

const ORIG_FETCH = globalThis.fetch;

afterEach(() => {
  resetAtprotoClientCachesForTests();
  globalThis.fetch = ORIG_FETCH;
});

describe("resolveLatrExternalSavedSubjectPreview", () => {
  it("reads persisted wrapper metadata without fetching the linked page", async () => {
    const requests: string[] = [];
    globalThis.fetch = mock(async (input: RequestInfo | URL) => {
      const url = String(input);
      requests.push(url);
      if (url.startsWith("https://plc.directory/")) {
        return Response.json({
          service: [
            {
              id: "#atproto_pds",
              type: "AtprotoPersonalDataServer",
              serviceEndpoint: "https://pds.example",
            },
          ],
        });
      }
      if (url.startsWith("https://pds.example/xrpc/com.atproto.repo.getRecord")) {
        return Response.json({
          value: {
            $type: "link.latr.saved.external",
            url: "https://news.example/story?utm_source=reader",
            normalizedUrl: "https://news.example/story",
            fingerprint: "abc",
            createdAt: "2026-07-27T12:00:00Z",
            title: "Saved story",
            excerpt: "A persisted summary",
            image: "http://cdn.example/story.jpg",
            site: "News Example",
            author: "Ada",
          },
        });
      }
      throw new Error(`Unexpected request: ${url}`);
    }) as unknown as typeof fetch;

    const preview = await resolveLatrExternalSavedSubjectPreview(
      "at://did:plc:viewer/link.latr.saved.external/wrapper"
    );

    expect(preview).toEqual({
      url: "https://news.example/story?utm_source=reader",
      normalizedUrl: "https://news.example/story",
      title: "Saved story",
      excerpt: "A persisted summary",
      image: "https://cdn.example/story.jpg",
      site: "News Example",
      author: "Ada",
    });
    expect(requests).toHaveLength(2);
    expect(requests[1]).toContain("collection=link.latr.saved.external");
    expect(requests[1]).toContain("rkey=wrapper");
  });

  it("ignores non-wrapper subjects", async () => {
    const fetchMock = mock(async () => {
      throw new Error("Should not fetch");
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    expect(
      await resolveLatrExternalSavedSubjectPreview(
        "at://did:plc:author/app.bsky.feed.post/post"
      )
    ).toBeNull();
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
