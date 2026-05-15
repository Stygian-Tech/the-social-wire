import { describe, it, expect } from "bun:test";
import {
  looksLikeOAuthScopeOrSessionError,
  looksLikeStaleOAuthStorageError,
} from "@/lib/oauthSessionSignals";

describe("looksLikeStaleOAuthStorageError", () => {
  it("detects oauth-client IndexedDB cross-process eviction message", () => {
    expect(
      looksLikeStaleOAuthStorageError(
        new Error("The session was deleted by another process")
      )
    ).toBe(true);
  });

  it("handles cause chain", () => {
    expect(
      looksLikeStaleOAuthStorageError(
        new Error("wrap", { cause: new Error("deleted by another process") })
      )
    ).toBe(true);
  });

  it("ignores unrelated errors", () => {
    expect(looksLikeStaleOAuthStorageError(new Error("ENOTFOUND"))).toBe(false);
  });
});

describe("looksLikeOAuthScopeOrSessionError", () => {
  it("includes stale storage", () => {
    expect(
      looksLikeOAuthScopeOrSessionError(
        new Error("The session was deleted by another process")
      )
    ).toBe(true);
  });

  it("still matches 401 messages", () => {
    expect(looksLikeOAuthScopeOrSessionError(new Error("request failed with 401"))).toBe(
      true
    );
  });
});
