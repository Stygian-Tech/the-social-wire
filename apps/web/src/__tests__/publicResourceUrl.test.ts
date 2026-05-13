import { describe, it, expect } from "bun:test";
import { normalizeHttpUrlToHttps, thumbnailImageSrcAttempts } from "@/lib/publicResourceUrl";

describe("normalizeHttpUrlToHttps", () => {
  it("promotes http to https", () => {
    expect(normalizeHttpUrlToHttps("http://atproto.brid.gy/xrpc/foo")).toBe(
      "https://atproto.brid.gy/xrpc/foo"
    );
  });

  it("strips bridge_completed query param", () => {
    expect(
      normalizeHttpUrlToHttps(
        "https://blog.example/post/slug?bridge_completed=1&utm_source=x"
      )
    ).toBe("https://blog.example/post/slug?utm_source=x");
  });

  it("is idempotent for https origins", () => {
    expect(normalizeHttpUrlToHttps("https://pds.example/xrpc/a")).toBe(
      "https://pds.example/xrpc/a"
    );
  });
});

describe("thumbnailImageSrcAttempts", () => {
  it("normalizes candidates and never inserts http fallbacks", () => {
    expect(
      thumbnailImageSrcAttempts(
        "http://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=a&cid=b",
        "https://img.example/thumb.png"
      )
    ).toEqual([
      "https://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=a&cid=b",
      "https://img.example/thumb.png",
    ]);
  });

  it("dedupes identical primary and fallback after normalization", () => {
    expect(
      thumbnailImageSrcAttempts(
        "http://cdn.example/x",
        "https://cdn.example/x"
      )
    ).toEqual(["https://cdn.example/x"]);
  });
});
