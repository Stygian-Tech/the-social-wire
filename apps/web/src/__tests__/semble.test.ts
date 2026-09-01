import { describe, expect, it } from "bun:test";

import {
  readLaterQueryKeys,
  readLaterCapabilities,
  normalizeSembleUrl,
  normalizeSembleConnectionEndpoint,
  tokenScopesAllowSemble,
} from "@/lib/semble";
import { sembleMembershipRemovalKind } from "@/lib/semblePdsClient";

const grants = [
  "network.cosmik.card",
  "network.cosmik.collection",
  "network.cosmik.collectionLink",
  "network.cosmik.collectionLinkRemoval",
  "network.cosmik.connection",
].map(
  (collection) =>
    `repo:${collection}?action=create&action=update&action=delete`,
);

describe("Semble provider contracts", () => {
  it("normalizes URLs for direct-PDS card deduplication", () => {
    expect(normalizeSembleUrl("HTTP://Example.COM:80/#section")).toBe(
      "https://example.com/",
    );
    expect(normalizeSembleUrl("example.com/article#comments")).toBe(
      "https://example.com/article",
    );
    expect(normalizeSembleUrl("at://did:plc:test/network.cosmik.card/1")).toBeNull();
  });

  it("preserves official URL or AT-URI connection endpoints", () => {
    expect(normalizeSembleConnectionEndpoint("HTTP://Example.COM/path#one")).toBe(
      "https://example.com/path",
    );
    expect(
      normalizeSembleConnectionEndpoint(
        "at://did:plc:author/network.cosmik.card/card",
      ),
    ).toBe("at://did:plc:author/network.cosmik.card/card");
  });

  it("requires all five explicit Semble repo grants", () => {
    expect(tokenScopesAllowSemble(grants.join(" "))).toBe(true);
    expect(tokenScopesAllowSemble("include:network.cosmik.authFull")).toBe(false);
    expect(tokenScopesAllowSemble(grants.slice(0, -1).join(" "))).toBe(false);
  });

  it("scopes caches by viewer, provider, and collection", () => {
    expect(
      readLaterQueryKeys.items(
        "did:plc:viewer",
        "semble",
        "at://did:plc:viewer/network.cosmik.collection/readlater",
      ),
    ).toEqual([
      "readLater",
      "did:plc:viewer",
      "semble",
      "collection",
      "at://did:plc:viewer/network.cosmik.collection/readlater",
      "items",
    ]);
  });

  it("exposes provider-neutral capabilities", () => {
    expect(readLaterCapabilities("semble")).toEqual({
      archive: false,
      tags: false,
      notes: true,
      connections: true,
      collectionMembership: true,
    });
    expect(readLaterCapabilities("latr-gateway").archive).toBe(true);
  });

  it("deletes viewer-owned links and tombstones external contributions", () => {
    expect(
      sembleMembershipRemovalKind(
        "did:plc:viewer",
        "at://did:plc:viewer/network.cosmik.collectionLink/one",
      ),
    ).toBe("delete-own-link");
    expect(
      sembleMembershipRemovalKind(
        "did:plc:viewer",
        "at://did:plc:contributor/network.cosmik.collectionLink/two",
      ),
    ).toBe("create-removal");
    expect(sembleMembershipRemovalKind("did:plc:viewer", null)).toBe(
      "unavailable",
    );
  });
});
