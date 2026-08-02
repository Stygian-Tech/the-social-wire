import { afterEach, describe, expect, it, mock } from "bun:test";
import {
  ACTOR_TYPEAHEAD_SERVICE_URL,
  loginHandleSearchQuery,
  searchLoginHandles,
} from "@/lib/loginHandleTypeahead";

const originalFetch = globalThis.fetch;

afterEach(() => {
  globalThis.fetch = originalFetch;
});

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
    expect(loginHandleSearchQuery("https://alice.example")).toBeNull();
    expect(loginHandleSearchQuery("alice smith")).toBeNull();
  });

  it("uses the WAOW Bluesky-compatible XRPC endpoint", async () => {
    const fetchMock = mock(async (input: RequestInfo | URL) => {
      const url = new URL(String(input));
      expect(url.origin).toBe(ACTOR_TYPEAHEAD_SERVICE_URL);
      expect(url.pathname).toBe(
        "/xrpc/app.bsky.actor.searchActorsTypeahead"
      );
      expect(url.searchParams.get("q")).toBe("alice");
      expect(url.searchParams.get("limit")).toBe("6");
      return Response.json({
        actors: [
          {
            did: "did:plc:alice",
            handle: "alice.example",
            displayName: "Alice",
          },
        ],
      });
    });
    globalThis.fetch = fetchMock as unknown as typeof fetch;

    await expect(searchLoginHandles("@alice")).resolves.toEqual([
      {
        did: "did:plc:alice",
        handle: "alice.example",
        displayName: "Alice",
        avatar: undefined,
      },
    ]);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
