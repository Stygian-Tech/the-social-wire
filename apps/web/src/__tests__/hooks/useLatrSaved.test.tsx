import { describe, expect, it } from "bun:test";
import { normalizeLatrHttpsUrl } from "@/lib/latrSavedUrls";

describe("useLatrSaved helpers", () => {
  it("normalizes HTTPS URLs for L@tr keys", () => {
    expect(normalizeLatrHttpsUrl("https://Example.com/path/")).toBe(
      "https://example.com/path"
    );
  });
});
