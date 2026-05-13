import { describe, it, expect } from "bun:test";
import {
  normalizeHttpUrlToHttps,
  sanitizeEmbedUrlForIframe,
  thumbnailImageSrcAttempts,
} from "@/lib/publicResourceUrl";

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

  it("strips bridge_* and /^bridge/i query keys (incl. bridgeCompleted, Bridge_completed)", () => {
    expect(
      normalizeHttpUrlToHttps(
        "https://blog.stygiantech.dev/pieces/good-writing?bridge_completed=1"
      )
    ).toBe("https://blog.stygiantech.dev/pieces/good-writing");
    expect(
      normalizeHttpUrlToHttps(
        "https://blog.stygiantech.dev/a/b?utm=x&Bridge_completed=yes&bridge_foo=z"
      )
    ).toBe("https://blog.stygiantech.dev/a/b?utm=x");
    expect(
      normalizeHttpUrlToHttps("https://ex.com/x?bridgeCompleted=1&keep=1")
    ).toBe("https://ex.com/x?keep=1");
  });

  it("keeps completed= when no /^bridge/i key is present", () => {
    expect(
      normalizeHttpUrlToHttps("https://ex.com/a?completed=1&other=2")
    ).toBe("https://ex.com/a?completed=1&other=2");
  });

  it("drops completed when a /^bridge/i key was present before cleanup", () => {
    expect(
      normalizeHttpUrlToHttps("https://ex.com/a?bridgeFoo=1&completed=1")
    ).toBe("https://ex.com/a");
  });

  it("strips Bridge_completed case-insensitively alongside other params", () => {
    expect(
      normalizeHttpUrlToHttps(
        "https://blog.example/p?Bridge_completed=1&y=1"
      )
    ).toBe("https://blog.example/p?y=1");
  });

  it("is idempotent for https origins", () => {
    expect(normalizeHttpUrlToHttps("https://pds.example/xrpc/a")).toBe(
      "https://pds.example/xrpc/a"
    );
  });
});


describe("sanitizeEmbedUrlForIframe", () => {
  it("strips all query params on *.brid.gy hosts", () => {
    expect(
      sanitizeEmbedUrlForIframe("https://foo.brid.gy/post?bridge_x=1&utm=y")
    ).toBe("https://foo.brid.gy/post");
  });

  it("applies HTTPS + bridge cleanup on non-brid.gy hosts", () => {
    expect(
      sanitizeEmbedUrlForIframe(
        "http://blog.stygiantech.dev/x?Bridge_completed=1"
      )
    ).toBe("https://blog.stygiantech.dev/x");
  });
});

describe("thumbnailImageSrcAttempts", () => {
  it("drops Bridgy sync.getBlob when a non-bridgy candidate exists (order: HTTPS effective first)", () => {
    expect(
      thumbnailImageSrcAttempts(
        "http://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=a&cid=b",
        "https://img.example/thumb.png"
      )
    ).toEqual(["https://img.example/thumb.png"]);
  });

  it("omits Bridgy sync.getBlob when it is the only candidate (avoid predictable 400 GETs)", () => {
    expect(
      thumbnailImageSrcAttempts(
        "https://atproto.brid.gy/xrpc/com.atproto.sync.getBlob?did=a&cid=b"
      )
    ).toEqual([]);
  });

  it("keeps ordinary PDS getBlob URLs", () => {
    expect(
      thumbnailImageSrcAttempts(
        "https://pds.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Ax&cid=bafy"
      )
    ).toEqual([
      "https://pds.example/xrpc/com.atproto.sync.getBlob?did=did%3Aplc%3Ax&cid=bafy",
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
