import { afterEach, describe, expect, it, mock } from "bun:test";

import {
  fetchCachedImageObjectUrl,
  isDirectImageLoadUrl,
  resolveDirectImageUrl,
  shouldUseDirectImageSrc,
} from "@/lib/imageBlobCache";

const originalFetch = globalThis.fetch;
const originalCreateObjectUrl = URL.createObjectURL;

afterEach(() => {
  globalThis.fetch = originalFetch;
  URL.createObjectURL = originalCreateObjectUrl;
});

describe("image direct src resolution", () => {
  it("uses direct img src for cross-origin CDN hosts without CORS", () => {
    const url =
      "https://cdn.bsky.app/img/avatar/plain/did:plc:abc/bafy";
    expect(isDirectImageLoadUrl(url)).toBe(true);
    expect(shouldUseDirectImageSrc(url)).toBe(true);
    expect(resolveDirectImageUrl(url)).toBe(url);
  });

  it("loads bundled mock-reader images directly in SSR and the browser", () => {
    const url = "/mock-reader/thumbnail-coral.svg";

    expect(isDirectImageLoadUrl(url)).toBe(true);
    expect(resolveDirectImageUrl(url)).toBe(url);
  });

  it("keeps other root-relative images on the same-origin cache path", () => {
    const url = "/api/image-proxy/publication-icon";

    expect(isDirectImageLoadUrl(url)).toBe(false);
    expect(resolveDirectImageUrl(url)).toBeUndefined();
  });

  it("gives concurrent consumers independent blob URLs", async () => {
    const fetchMock = mock(async () =>
      new Response("<svg />", {
        status: 200,
        headers: { "Content-Type": "image/svg+xml" },
      }),
    );
    let objectUrlSequence = 0;
    globalThis.fetch = Object.assign(fetchMock, {
      preconnect: originalFetch.preconnect,
    }) as typeof fetch;
    URL.createObjectURL = mock(
      () => `blob:http://localhost/image-${++objectUrlSequence}`,
    );

    const [first, second] = await Promise.all([
      fetchCachedImageObjectUrl("/test/concurrent.svg"),
      fetchCachedImageObjectUrl("/test/concurrent.svg"),
    ]);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(first).not.toBe(second);
    expect(first).toStartWith("blob:");
    expect(second).toStartWith("blob:");
  });
});
