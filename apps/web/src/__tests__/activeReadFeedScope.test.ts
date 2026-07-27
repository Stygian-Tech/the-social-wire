import { describe, expect, it } from "bun:test";

import { activeReadFeedScope } from "@/lib/activeReadFeedScope";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

const subscribed: DiscoveredPublication = {
  publicationId: "subscribed",
  subscriptionPublicationId: "subscribed",
  authorDid: "did:plc:subscribed",
  authorHandle: "subscribed.test",
  title: "Subscribed",
  discoveredAt: "2026-01-01T00:00:00.000Z",
};
const following: DiscoveredPublication = {
  ...subscribed,
  publicationId: "following",
  subscriptionPublicationId: "following",
  title: "Following",
};

describe("activeReadFeedScope", () => {
  it("maps each exclusive selection to one server scope", () => {
    const common = {
      folderPublications: [subscribed],
      subscribedPublications: [subscribed],
      followingPublications: [following],
    };

    expect(
      activeReadFeedScope({
        ...common,
        folderRkey: null,
        selectedTopLevelFeed: "subscribed",
      }).gatewayScope,
    ).toEqual({ kind: "subscribed" });
    expect(
      activeReadFeedScope({
        ...common,
        folderRkey: null,
        selectedTopLevelFeed: "following",
      }).gatewayScope,
    ).toEqual({ kind: "following" });
    expect(
      activeReadFeedScope({
        ...common,
        folderRkey: "product",
        selectedTopLevelFeed: "subscribed",
      }).gatewayScope,
    ).toEqual({ kind: "folder", folderRkey: "product" });
    expect(
      activeReadFeedScope({
        ...common,
        folderRkey: null,
        selectedPublication: following,
        selectedTopLevelFeed: "subscribed",
      }).gatewayScope,
    ).toEqual({ kind: "publication", publicationId: "following" });
  });
});
