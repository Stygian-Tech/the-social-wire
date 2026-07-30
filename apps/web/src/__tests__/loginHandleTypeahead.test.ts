import { describe, expect, it } from "bun:test";
import { loginHandleSearchQuery } from "@/lib/loginHandleTypeahead";

describe("login handle typeahead", () => {
  it("normalizes handles before searching", () => {
    expect(loginHandleSearchQuery(" @alice.bsky.social ")).toBe(
      "alice.bsky.social"
    );
    expect(loginHandleSearchQuery("alice")).toBe("alice");
  });

  it("does not search incomplete, DID, or whitespace input", () => {
    expect(loginHandleSearchQuery("a")).toBeNull();
    expect(loginHandleSearchQuery("did:plc:alice")).toBeNull();
    expect(loginHandleSearchQuery("alice smith")).toBeNull();
  });
});
