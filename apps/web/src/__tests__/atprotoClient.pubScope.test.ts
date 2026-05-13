import { describe, it, expect } from "bun:test";
import {
  computeNextListEntriesPageCursor,
  normalizeAtRepoParam,
  normalizeDidForOwnershipCompare,
  publicationRepoDid,
  repoAndPublicationFilterFromPubId,
  sortEntryListItemsNewestFirst,
  viewerOwnsDiscoveredPublication,
} from "@/lib/atprotoClient";

describe("normalizeAtRepoParam", () => {
  it("decodes a single-encoded DID segment to a DID", () => {
    expect(normalizeAtRepoParam("did%3Aplc%3Axyz")).toBe("did:plc:xyz");
  });

  it("decodes a double-encoded DID segment", () => {
    expect(normalizeAtRepoParam("did%253Aplc%253Axyz")).toBe("did:plc:xyz");
  });

  it("trims and strips a leading @ before decoding", () => {
    expect(normalizeAtRepoParam("  @did%3Aplc%3Ax  ")).toBe("did:plc:x");
  });
});

describe("repoAndPublicationFilterFromPubId", () => {
  it("uses plain DID as repo key with no publication filter", () => {
    expect(repoAndPublicationFilterFromPubId("did:plc:abc")).toEqual({
      repoDid: "did:plc:abc",
      publicationAtUri: undefined,
    });
  });

  it("accepts a URL-encoded DID as repo key", () => {
    expect(repoAndPublicationFilterFromPubId("did%3Aplc%3Aabc")).toEqual({
      repoDid: "did:plc:abc",
      publicationAtUri: undefined,
    });
  });

  it("derives repo DID and filter from a publication record AT-URI", () => {
    const uri =
      "at://did:plc:abc/site.standard.publication/3lmn4op56qr7s";
    expect(repoAndPublicationFilterFromPubId(uri)).toEqual({
      repoDid: "did:plc:abc",
      publicationAtUri: uri,
    });
  });

  it("supports com.standard.publication collection", () => {
    const uri = "at://did:plc:xyz/com.standard.publication/rkey1";
    expect(repoAndPublicationFilterFromPubId(uri)).toEqual({
      repoDid: "did:plc:xyz",
      publicationAtUri: uri,
    });
  });

  it("falls back to repoDid as full AT-URI for non-publication collections", () => {
    const uri = "at://did:plc:self/site.standard.document/key1";
    expect(repoAndPublicationFilterFromPubId(uri)).toEqual({
      repoDid: uri,
      publicationAtUri: undefined,
    });
  });
});

describe("publicationRepoDid", () => {
  it("returns the DID from a plain repo key", () => {
    expect(publicationRepoDid("did:plc:abc")).toBe("did:plc:abc");
  });

  it("returns repo owner from a publication AT-URI", () => {
    const uri =
      "at://did:plc:mine/site.standard.publication/3lmn4op56qr7s";
    expect(publicationRepoDid(uri)).toBe("did:plc:mine");
  });

  it("extracts DID when repoAndPublicationFilterFromPubId returns an entry-style AT-URI", () => {
    const uri = "at://did:plc:self/site.standard.entry/rkey77";
    expect(publicationRepoDid(uri)).toBe("did:plc:self");
  });
});

describe("normalizeDidForOwnershipCompare", () => {
  it("lowercases did:plc identifiers", () => {
    expect(normalizeDidForOwnershipCompare("DID:PLC:AbC12")).toBe(
      "did:plc:abc12"
    );
  });
});

describe("viewerOwnsDiscoveredPublication", () => {
  const me = "did:plc:viewer123";

  it("is true when publicationId is the viewer DID (aggregate feed)", () => {
    expect(
      viewerOwnsDiscoveredPublication({ publicationId: me }, me)
    ).toBe(true);
  });

  it("matches publication AT-URI when session.did differs only by did:plc casing", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId:
            "at://did:plc:VIEWER123/site.standard.publication/key1",
        },
        me
      )
    ).toBe(true);
  });

  it("is true when publicationId is an AT-URI on the viewer repo", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId:
            "at://did:plc:viewer123/site.standard.publication/key1",
        },
        me
      )
    ).toBe(true);
  });

  it("falls back to authorDid when publication AT-URI authority is a handle, not session DID", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId:
            "at://writewithbloom.com/site.standard.publication/build-notes",
          authorDid: me,
        },
        me
      )
    ).toBe(true);
  });

  it("falls back to authorDid when publicationId is not a resolvable ownership key", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId: "3kxwrisky17d2",
          authorDid: me,
        },
        me
      )
    ).toBe(true);
  });

  it("is false for another repo", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        { publicationId: "did:plc:someoneelse" },
        me
      )
    ).toBe(false);
  });

  it("does not treat another author's pub as owned when only publicationId is wrong", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId: "3kxwrisky17d2",
          authorDid: "did:plc:someoneelse",
        },
        me
      )
    ).toBe(false);
  });

  it("does not depend on authorDid (repo id is source of truth)", () => {
    expect(
      viewerOwnsDiscoveredPublication(
        {
          publicationId:
            "at://did:plc:viewer123/com.standard.publication/r1",
        },
        me
      )
    ).toBe(true);
  });
});

const FOUR_COLLECTION_FEEDS = 4;

describe("computeNextListEntriesPageCursor", () => {
  it("returns the same-collection cursor when the PDS returns a next cursor", () => {
    expect(
      computeNextListEntriesPageCursor(0, FOUR_COLLECTION_FEEDS, "next-token")
    ).toBe(`0:${encodeURIComponent("next-token")}`);
  });

  it("advances to the next collection when the current slice has no PDS cursor", () => {
    expect(
      computeNextListEntriesPageCursor(0, FOUR_COLLECTION_FEEDS, undefined)
    ).toBe("1:");
    expect(
      computeNextListEntriesPageCursor(2, FOUR_COLLECTION_FEEDS, undefined)
    ).toBe("3:");
  });

  it("returns undefined after the last collection with no PDS cursor", () => {
    expect(
      computeNextListEntriesPageCursor(3, FOUR_COLLECTION_FEEDS, undefined)
    ).toBeUndefined();
  });
});

describe("sortEntryListItemsNewestFirst", () => {
  it("orders by publishedAt descending and breaks ties by entryId", () => {
    const a = {
      entryId: "at://did/x/site.standard.document/a",
      title: "A",
      publishedAt: "2025-01-01T12:00:00.000Z",
    };
    const b = {
      entryId: "at://did/x/site.standard.document/b",
      title: "B",
      publishedAt: "2025-06-01T08:00:00.000Z",
    };
    const c = {
      entryId: "at://did/x/site.standard.document/c",
      title: "C",
      publishedAt: "2025-06-01T08:00:00.000Z",
    };
    const sorted = sortEntryListItemsNewestFirst([a, b, c]);
    expect(sorted.map((e) => e.entryId)).toEqual([b.entryId, c.entryId, a.entryId]);
  });
});
