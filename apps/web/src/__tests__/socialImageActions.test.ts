import { afterEach, describe, expect, it, mock, spyOn } from "bun:test";
import {
  copySocialImageBlob,
  fetchSocialImageBlob,
  saveSocialImageBlob,
  socialImageFilename,
} from "@/components/Social/socialImageActions";

const originalFetch = globalThis.fetch;
const clipboard = Object.getOwnPropertyDescriptor(navigator, "clipboard");
const clipboardItem = Object.getOwnPropertyDescriptor(
  globalThis,
  "ClipboardItem",
);
afterEach(() => {
  globalThis.fetch = originalFetch;
  if (clipboard) Object.defineProperty(navigator, "clipboard", clipboard);
  else Reflect.deleteProperty(navigator, "clipboard");
  if (clipboardItem)
    Object.defineProperty(globalThis, "ClipboardItem", clipboardItem);
  else Reflect.deleteProperty(globalThis, "ClipboardItem");
});
function setFetch(fn: (url: string) => Promise<Response>) {
  globalThis.fetch = Object.assign(mock(fn), {
    preconnect: originalFetch.preconnect,
  }) as typeof fetch;
}

describe("Social Original Image Actions", () => {
  it("uses the existing Bluesky CORS proxy and preserves original bytes and MIME", async () => {
    setFetch(async (url) => {
      expect(url).toBe(
        `/api/bluesky-card-thumb?${new URLSearchParams({ url: "https://cdn.bsky.app/img/feed_fullsize/plain/example@jpeg", purpose: "original" })}`,
      );
      return new Response(new Uint8Array([1, 2, 3]), {
        headers: { "content-type": "image/jpeg" },
      });
    });
    const blob = await fetchSocialImageBlob(
      "https://cdn.bsky.app/img/feed_fullsize/plain/example@jpeg",
    );
    expect(blob.type).toBe("image/jpeg");
    expect([...new Uint8Array(await blob.arrayBuffer())]).toEqual([1, 2, 3]);
    expect(socialImageFilename(blob)).toBe("social-wire-image.jpg");
  });
  it("falls back to the validated same-origin proxy on remote CORS failure", async () => {
    let requests = 0;
    setFetch(async (url) => {
      requests++;
      if (requests === 1) throw new TypeError("Failed to fetch");
      expect(url).toStartWith("/api/bluesky-card-thumb?");
      return new Response("original", {
        headers: { "content-type": "image/png" },
      });
    });
    expect(
      (await fetchSocialImageBlob("https://publisher.example/original.png"))
        .type,
    ).toBe("image/png");
    expect(requests).toBe(2);
  });
  it("reports unsafe URLs, failed originals and non-image responses", async () => {
    await expect(fetchSocialImageBlob("javascript:alert(1)")).rejects.toThrow(
      "URL",
    );
    setFetch(async () => new Response("too large", { status: 413 }));
    await expect(
      fetchSocialImageBlob("https://cdn.bsky.app/large"),
    ).rejects.toThrow("downloaded");
    setFetch(
      async () =>
        new Response("not an image", {
          headers: { "content-type": "text/html" },
        }),
    );
    await expect(
      fetchSocialImageBlob("https://publisher.example/fake.jpg"),
    ).rejects.toThrow("unavailable");
  });
  it("does not retry an aborted original fetch through the proxy", async () => {
    const controller = new AbortController();
    controller.abort();
    let calls = 0;
    setFetch(async () => {
      calls++;
      throw new DOMException("Cancelled", "AbortError");
    });
    await expect(
      fetchSocialImageBlob(
        "https://publisher.example/image.jpg",
        controller.signal,
      ),
    ).rejects.toThrow();
    expect(calls).toBe(1);
  });
  it("copies actual supported image bytes without conversion", async () => {
    const writes: unknown[] = [];
    class FakeClipboardItem {
      static supports(type: string) {
        return type === "image/jpeg";
      }
      constructor(readonly data: Record<string, Blob | Promise<Blob>>) {}
    }
    Object.defineProperty(globalThis, "ClipboardItem", {
      configurable: true,
      value: FakeClipboardItem,
    });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        write: async (items: unknown[]) => {
          writes.push(...items);
        },
      },
    });
    const blob = new Blob(["jpeg bytes"], { type: "image/jpeg" });
    await copySocialImageBlob(blob);
    expect((writes[0] as FakeClipboardItem).data["image/jpeg"]).toBe(blob);
    expect(Object.keys((writes[0] as FakeClipboardItem).data)).toEqual([
      "image/jpeg",
    ]);
  });
  it("converts unsupported clipboard formats to PNG while retaining original downloads", async () => {
    const originalImage = Object.getOwnPropertyDescriptor(globalThis, "Image");
    class DecodedImage {
      src = "";
      naturalWidth = 320;
      naturalHeight = 640;
      decode() {
        return Promise.resolve();
      }
    }
    class PngClipboardItem {
      static supports() {
        return false;
      }
      constructor(readonly data: Record<string, Blob | Promise<Blob>>) {}
    }
    Object.defineProperty(globalThis, "Image", {
      configurable: true,
      value: DecodedImage,
    });
    Object.defineProperty(globalThis, "ClipboardItem", {
      configurable: true,
      value: PngClipboardItem,
    });
    const create = spyOn(URL, "createObjectURL").mockReturnValue(
      "blob:clipboard-conversion",
    );
    const revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
    const context = spyOn(
      window.HTMLCanvasElement.prototype,
      "getContext",
    ).mockReturnValue({
      drawImage() {},
    } as unknown as CanvasRenderingContext2D);
    const encoded = new Blob(["png clipboard bytes"], { type: "image/png" });
    const toBlob = spyOn(
      window.HTMLCanvasElement.prototype,
      "toBlob",
    ).mockImplementation(function (
      this: HTMLCanvasElement,
      callback: BlobCallback,
      type?: string,
    ) {
      expect(this.width).toBe(320);
      expect(this.height).toBe(640);
      expect(type).toBe("image/png");
      callback(encoded);
    });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        write: async (items: PngClipboardItem[]) => {
          expect(Object.keys(items[0].data)).toEqual(["image/png"]);
          expect(await items[0].data["image/png"]).toBe(encoded);
        },
      },
    });
    try {
      const original = new Blob(["webp original bytes"], {
        type: "image/webp",
      });
      await copySocialImageBlob(original);
      expect(socialImageFilename(original)).toBe("social-wire-image.webp");
      expect(await original.text()).toBe("webp original bytes");
      expect(revoke).toHaveBeenCalledWith("blob:clipboard-conversion");
    } finally {
      create.mockRestore();
      revoke.mockRestore();
      context.mockRestore();
      toBlob.mockRestore();
      if (originalImage)
        Object.defineProperty(globalThis, "Image", originalImage);
      else Reflect.deleteProperty(globalThis, "Image");
    }
  });
  it("fails explicitly when clipboard image APIs are missing or denied", async () => {
    Reflect.deleteProperty(globalThis, "ClipboardItem");
    await expect(
      copySocialImageBlob(new Blob(["png"], { type: "image/png" })),
    ).rejects.toThrow("unavailable");
    class FakeClipboardItem {
      constructor(readonly data: unknown) {}
    }
    Object.defineProperty(globalThis, "ClipboardItem", {
      configurable: true,
      value: FakeClipboardItem,
    });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        write: async () => {
          throw new Error("Clipboard permission denied");
        },
      },
    });
    await expect(
      copySocialImageBlob(new Blob(["png"], { type: "image/png" })),
    ).rejects.toThrow("permission denied");
  });
  it("downloads a local original blob with its actual extension", () => {
    const create = spyOn(URL, "createObjectURL").mockReturnValue(
      "blob:original-image",
    );
    let file = "";
    const click = spyOn(
      window.HTMLAnchorElement.prototype,
      "click",
    ).mockImplementation(function (this: HTMLAnchorElement) {
      file = this.download;
      expect(this.href).toBe("blob:original-image");
    });
    try {
      saveSocialImageBlob(new Blob(["gif bytes"], { type: "image/gif" }));
      expect(file).toBe("social-wire-image.gif");
      expect(document.querySelector("a[download]")).toBeNull();
    } finally {
      create.mockRestore();
      click.mockRestore();
    }
  });
});
