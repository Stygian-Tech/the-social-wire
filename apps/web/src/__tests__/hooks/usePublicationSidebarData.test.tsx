import { describe, expect, it } from "bun:test";
import {
  addPublicationSubscriptionLookupKeys,
  publicationSubscriptionMatchKeys,
} from "@/lib/publicationSubscriptionMatch";
import type { DiscoveredPublication } from "@/lib/atprotoClient";

const pub: DiscoveredPublication = {
  publicationId: "at://did:plc:author/site.standard.publication/key1",
  subscriptionPublicationId: "at://did:plc:author/site.standard.publication/key1",
  authorDid: "did:plc:author",
  authorHandle: "author.test",
  title: "Pub",
  iconUrl: null,
  avatarUrl: null,
  discoveredAt: "2026-01-01T00:00:00.000Z",
};

describe("usePublicationSidebarData helpers", () => {
  it("subscription keys intersect discovered publication keys", () => {
    const keys = new Set<string>();
    addPublicationSubscriptionLookupKeys(keys, "did:plc:author");
    const matchKeys = publicationSubscriptionMatchKeys(pub);
    expect(matchKeys.some((k) => keys.has(k))).toBe(true);
  });
});
