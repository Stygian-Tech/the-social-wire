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

const requiredGrants = [
  "repo:network.cosmik.card?action=create",
  "repo:network.cosmik.card?action=update",
  "repo:network.cosmik.collectionLink?action=create",
  "repo:network.cosmik.collectionLink?action=delete",
  "repo:network.cosmik.collectionLinkRemoval?action=create",
  "repo:network.cosmik.connection?action=create",
  "repo:network.cosmik.connection?action=update",
];

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

  it("accepts only the actions used by Semble without collection writes", () => {
    expect(tokenScopesAllowSemble(requiredGrants.join(" "))).toBe(true);
    expect(
      tokenScopesAllowSemble(
        "repo:network.cosmik.card?action=create&action=update " +
          "repo:network.cosmik.collectionLink?action=create&action=delete " +
          "repo:network.cosmik.collectionLinkRemoval?action=create " +
          "repo:network.cosmik.connection?action=create&action=update",
      ),
    ).toBe(true);
  });

  it("continues accepting broader existing collection and wildcard grants", () => {
    expect(tokenScopesAllowSemble(grants.join(" "))).toBe(true);
    expect(tokenScopesAllowSemble("repo:*")).toBe(true);
    expect(
      tokenScopesAllowSemble("repo:*?action=create&action=update&action=delete"),
    ).toBe(true);
  });

  it.each(requiredGrants)("requires the implemented action %s", (requiredGrant) => {
    expect(
      tokenScopesAllowSemble(
        requiredGrants.filter((grant) => grant !== requiredGrant).join(" "),
      ),
    ).toBe(false);
  });

  it("rejects missing or insufficient grants", () => {
    expect(tokenScopesAllowSemble(undefined)).toBe(false);
    expect(tokenScopesAllowSemble("repo:*?action=create")).toBe(false);
    expect(tokenScopesAllowSemble("include:network.cosmik.authFull")).toBe(false);
    expect(
      tokenScopesAllowSemble(
        requiredGrants
          .join(" ")
          .replace("repo:network.cosmik.card", "repo:network.cosmik.collection"),
      ),
    ).toBe(false);
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
