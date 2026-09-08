import { afterEach, beforeEach, describe, expect, it, spyOn } from "bun:test";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";

import * as ImageBlobCache from "@/lib/imageBlobCache";

// The editorial layout suite replaces this module globally. Load an independent
// instance so these lifecycle assertions exercise the real hook in the full run.
const hookModulePath = "../../hooks/useCachedImageUrl.ts?lifecycle-tests";
const { useCachedImageUrl } = await import(hookModulePath) as typeof import("@/hooks/useCachedImageUrl");

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => { resolve = res; });
  return { promise, resolve };
}

describe("cached image URL lifecycle", () => {
  let fetchImage: ReturnType<typeof spyOn<typeof ImageBlobCache, "fetchCachedImageObjectUrl">>;
  let revoke: ReturnType<typeof spyOn<typeof URL, "revokeObjectURL">>;

  beforeEach(() => {
    fetchImage = spyOn(ImageBlobCache, "fetchCachedImageObjectUrl");
    revoke = spyOn(URL, "revokeObjectURL").mockImplementation(() => {});
  });

  afterEach(() => {
    cleanup();
    fetchImage.mockRestore();
    revoke.mockRestore();
  });

  it("uses direct publisher images without fetching and treats blank sources as empty", () => {
    const { result, rerender } = renderHook(
      ({ src }) => useCachedImageUrl(src),
      { initialProps: { src: " https://publisher.example/image.jpg " } },
    );
    expect(result.current).toEqual({ objectUrl: "https://publisher.example/image.jpg", failed: false });
    rerender({ src: "  " });
    expect(result.current).toEqual({ objectUrl: undefined, failed: false });
    expect(fetchImage).not.toHaveBeenCalled();
  });

  it("hides the prior image when the source changes and revokes each owned blob", async () => {
    const first = deferred<string | undefined>();
    const second = deferred<string | undefined>();
    fetchImage.mockReturnValueOnce(first.promise).mockReturnValueOnce(second.promise);
    const { result, rerender, unmount } = renderHook(
      ({ src }) => useCachedImageUrl(src),
      { initialProps: { src: "/test-images/first.png" } },
    );
    await act(async () => first.resolve("blob:first"));
    expect(result.current.objectUrl).toBe("blob:first");
    rerender({ src: "/test-images/second.png" });
    expect(result.current).toEqual({ objectUrl: undefined, failed: false });
    expect(revoke).toHaveBeenCalledWith("blob:first");
    await act(async () => second.resolve("blob:second"));
    expect(result.current.objectUrl).toBe("blob:second");
    unmount();
    expect(revoke).toHaveBeenCalledWith("blob:second");
  });

  it("discards a late result after the consumer switches to another source", async () => {
    const pending = deferred<string | undefined>();
    fetchImage.mockReturnValue(pending.promise);
    const { result, rerender } = renderHook(
      ({ src }) => useCachedImageUrl(src),
      { initialProps: { src: "/test-images/pending.png" } },
    );
    rerender({ src: "https://publisher.example/current.png" });
    await act(async () => pending.resolve("blob:cancelled"));
    expect(revoke).toHaveBeenCalledWith("blob:cancelled");
    expect(result.current.objectUrl).toBe("https://publisher.example/current.png");
  });

  it("reports a missing cached image and resets failure on the next source", async () => {
    fetchImage.mockResolvedValue(undefined);
    const { result, rerender } = renderHook(
      ({ src }) => useCachedImageUrl(src),
      { initialProps: { src: "/test-images/missing.png" } },
    );
    await waitFor(() => expect(result.current.failed).toBe(true));
    rerender({ src: "" });
    expect(result.current).toEqual({ objectUrl: undefined, failed: false });
  });

  it("reports a rejected image request without an unhandled rejection", async () => {
    fetchImage.mockRejectedValue(new Error("Offline"));
    const { result } = renderHook(() => useCachedImageUrl("/test-images/error.png"));
    await waitFor(() => expect(result.current).toEqual({ objectUrl: undefined, failed: true }));
  });
});
