import { describe, expect, it } from "bun:test";
import type { DiscoveredPublication } from "@/lib/atprotoClient";
import {
  addPublicationSubscriptionLookupKeys,
  publicationIdsMatch,
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
    expect(keys.has("did:plc:author")).toBe(false);
    expect(keys.has("at://did:plc:author/com.standard.publication/key1")).toBe(
      true
    );
  });

  it("does not cross-match two publications by the same author", () => {
    const pubA = makePublication(
      "at://did:plc:author/site.standard.publication/a",
      "did:plc:author"
    );
    const pubB = makePublication(
      "at://did:plc:author/site.standard.publication/b",
      "did:plc:author"
    );
    const subKeys = new Set<string>();
    addPublicationSubscriptionLookupKeys(
      subKeys,
      "at://did:plc:author/site.standard.publication/b"
    );
    expect(
      publicationSubscriptionMatchKeys(pubA).some((k) => subKeys.has(k))
    ).toBe(false);
    expect(
      publicationSubscriptionMatchKeys(pubB).some((k) => subKeys.has(k))
    ).toBe(true);
  });

  it("matches encoded publication ids and collection aliases", () => {
    expect(
      publicationIdsMatch(
        "at%3A%2F%2Fdid%3Aplc%3Aauthor%2Fsite.standard.publication%2Fkey1",
        "at://did:plc:author/com.standard.publication/key1"
      )
    ).toBe(true);
    expect(
      publicationIdsMatch(
        "rss:https%3A%2F%2Fexample.com%2Ffeed.xml",
        "rss:https%3A%2F%2Fexample.com%2Fother.xml"
      )
    ).toBe(false);
  });
});
