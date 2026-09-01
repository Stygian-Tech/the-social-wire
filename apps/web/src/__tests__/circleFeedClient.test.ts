import { describe, expect, it } from "bun:test";

import {
  CIRCLE_GRAPH_DPOP_HEADER,
  CIRCLE_GRAPH_PROOF_SPECS,
  circleCatalogRequest,
  circleEditionRequest,
  circleHiddenItemRequest,
  circleReasonLabel,
  circleStoryToEntryListItem,
} from "@/lib/circleFeedClient";
import {
  CIRCLE_CATALOG_QUERY_KEY,
  CIRCLE_EDITION_QUERY_KEY,
} from "@/hooks/useCircleFeed";

describe("Your Circle web client", () => {
  it("omits redundant relationship reasons from Circle cards", () => {
    expect(circleReasonLabel("shared_by_following")).toBeNull();
    expect(circleReasonLabel("shared_by_extended_circle")).toBeNull();
    expect(circleReasonLabel("popular_in_your_circle")).toBeNull();
    expect(circleReasonLabel("discussed_in_your_circle")).toBe(
      "Discussed In Your Circle",
    );
    expect(circleReasonLabel("fresh_from_your_circle")).toBe(
      "Fresh From Your Circle",
    );
    expect(circleReasonLabel("at.margin.note")).toBeNull();
  });

  it("uses viewer-scoped catalog and edition query keys", () => {
    expect(CIRCLE_CATALOG_QUERY_KEY("did:plc:alice")).not.toEqual(
      CIRCLE_CATALOG_QUERY_KEY("did:plc:bob"),
    );
    expect(CIRCLE_EDITION_QUERY_KEY("did:plc:alice", "en")).not.toEqual(
      CIRCLE_EDITION_QUERY_KEY("did:plc:bob", "en"),
    );
  });

  it("builds the authenticated catalog request on canonical XRPC", () => {
    expect(circleCatalogRequest()).toEqual({
      path: "/xrpc/app.thesocialwire.discovery.getCircleCatalog",
      init: { method: "GET" },
    });
  });

  it("binds edition paging to the complete Circle graph proof pool", () => {
    expect(CIRCLE_GRAPH_PROOF_SPECS.at(-1)).toEqual({
      xrpcMethod: "com.atproto.repo.listRecords",
      httpMethod: "GET",
    });
    expect(
      circleEditionRequest({
        language: "en",
        cursor: "next page",
        proofPool: "circle-proof-pool",
      }),
    ).toEqual({
      path: "/xrpc/app.thesocialwire.discovery.getCircleEdition?lang=en&cursor=next+page",
      init: {
        method: "GET",
        signal: undefined,
        cache: "default",
        headers: { [CIRCLE_GRAPH_DPOP_HEADER]: "circle-proof-pool" },
      },
    });
  });

  it("posts hide and undo state using the canonical story ID", () => {
    expect(
      circleHiddenItemRequest({ storyId: "story-1", hidden: false }),
    ).toEqual({
      path: "/xrpc/app.thesocialwire.discovery.setCircleItemHidden",
      init: {
        method: "POST",
        signal: undefined,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ storyId: "story-1", hidden: false }),
      },
    });
  });

  it("preserves public sharer metadata when adapting stories for editorial UI", () => {
    const entry = circleStoryToEntryListItem(
      {
        storyId: "story-1",
        canonicalUrl: "http://news.example/story",
        title: "Shared Story",
        source: { name: "News", domain: "news.example" },
        reasons: ["shared_by_following"],
        discussionCount: 3,
        sharerCount: 4,
        sharers: [
          {
            identity: { did: "did:plc:alice", handle: "alice.example" },
            relationship: "direct",
            action: "shared",
            sourceUri: "at://did:plc:alice/app.bsky.feed.post/one",
            timestamp: "2026-08-30T00:00:00Z",
          },
        ],
      },
      "2026-08-30T00:00:00Z",
    );

    expect(entry.originalUrl).toBe("https://news.example/story");
    expect(entry.circleItem?.storyId).toBe("story-1");
    expect(entry.circleItem?.sharerCount).toBe(4);
    expect(entry.circleItem?.sharers[0]?.identity.handle).toBe("alice.example");
  });
});
