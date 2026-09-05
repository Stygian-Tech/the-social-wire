import { describe, expect, it } from "bun:test";
import { QueryClient, type InfiniteData } from "@tanstack/react-query";
import {
  FeedResponseError, feedResponseError, isExpiredFeedCursor, refreshExpiredFeedCursor,
} from "@/lib/feedResponseError";

describe("expired discovery cursor recovery", () => {
  it("preserves the XRPC code and replaces all old-generation pages", async () => {
    const error = await feedResponseError(new Response(JSON.stringify({
      error: "CursorExpired", message: "The generation expired",
    }), { status: 410 }), "Feed failed");
    expect(isExpiredFeedCursor(error)).toBe(true);
    const client = new QueryClient();
    const key = ["feed", "viewer-a", "en"];
    const otherKey = ["feed", "viewer-b", "en"];
    const old = { pages: ["old-first", "old-tail"], pageParams: [undefined, "expired"] };
    client.setQueryData(key, old);
    client.setQueryData(otherKey, old);
    let refreshes = 0;
    await refreshExpiredFeedCursor(error, async () => {
      refreshes++;
      client.setQueryData(key, { pages: ["new-first"], pageParams: [undefined] });
    });
    expect(refreshes).toBe(1);
    expect(client.getQueryData<InfiniteData<string>>(key)?.pages).toEqual(["new-first"]);
    expect(client.getQueryData<InfiniteData<string>>(otherKey)?.pages).toEqual(old.pages);
  });

  it("does not turn authentication, malformed cursor or network failures into a refresh", async () => {
    for (const error of [new Error("CursorExpired"),
      new FeedResponseError("auth", "AuthRequired", 401),
      new FeedResponseError("bad cursor", "InvalidRequest", 400)]) {
      expect(await refreshExpiredFeedCursor(error, async () => {
        throw new Error("must not refresh");
      })).toBe(false);
    }
  });

  it("propagates first-page failure without recursively retrying", async () => {
    let requests = 0;
    await expect(refreshExpiredFeedCursor(new FeedResponseError("expired", "CursorExpired"),
      async () => { requests++; throw new Error("offline"); })).rejects.toThrow("offline");
    expect(requests).toBe(1);
  });
});
