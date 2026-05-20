import { describe, expect, it } from "bun:test";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  addPublicationSubscriptionLookupKeys,
  publicationSubscriptionMatchKeys,
  standardSiteSubscriptionTargetFromDiscovery,
} from "@/lib/publicationSubscriptionMatch";

function makePublication(
  publicationId: string,
  authorDid: string
): DiscoveredPublication {
  return {
    publicationId,
    subscriptionPublicationId: publicationId,
    authorDid,
    authorHandle: "handle.test",
    title: "Title",
    iconUrl: null,
    avatarUrl: null,
    discoveredAt: "2026-01-01T00:00:00.000Z",
  };
}

describe("publicationSubscriptionMatch", () => {
  it("standardSiteSubscriptionTargetFromDiscovery prefers publication AT-URI", () => {
    const pub = makePublication(
      "at://did:plc:author/site.standard.publication/key1",
      "did:plc:author"
    );
    expect(standardSiteSubscriptionTargetFromDiscovery(pub)).toBe(
      "at://did:plc:author/site.standard.publication/key1"
    );
  });

  it("standardSiteSubscriptionTargetFromDiscovery falls back to author DID", () => {
    const pub = makePublication("did:plc:author", "did:plc:author");
    expect(standardSiteSubscriptionTargetFromDiscovery(pub)).toBe(
      "did:plc:author"
    );
  });

  it("publicationSubscriptionMatchKeys includes alternate collection", () => {
    const pub = makePublication(
      "at://did:plc:author/site.standard.publication/key1",
      "did:plc:author"
    );
    const keys = publicationSubscriptionMatchKeys(pub);
    expect(keys).toContain(
      "at://did:plc:author/com.standard.publication/key1"
    );
  });

  it("addPublicationSubscriptionLookupKeys adds DID and AT-URI keys", () => {
    const keys = new Set<string>();
    addPublicationSubscriptionLookupKeys(keys, "did:plc:alice");
    expect(keys.has("did:plc:alice")).toBe(true);

    keys.clear();
    addPublicationSubscriptionLookupKeys(
      keys,
      "at://did:plc:author/site.standard.publication/key1"
    );
    expect(keys.has("did:plc:author")).toBe(true);
    expect(keys.has("at://did:plc:author/com.standard.publication/key1")).toBe(
      true
    );
  });
});
