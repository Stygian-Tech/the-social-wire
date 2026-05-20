import { describe, it, expect } from "bun:test";
import {
  computeNextListEntriesPageCursor,
  decodeListEntriesPageCursor,
  decodePublicationScopeListCursor,
  entryRecordMatchesPublication,
  entryRecordMatchesPublicationScope,
  type PublicationScopeMatch,
  normalizeAtRepoParam,
  normalizeDidForOwnershipCompare,
  parseAtUri,
  publicationRepoDid,
  readRoutePubIdFromSegments,
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

  it("does not decode percent-encoding inside a parseable AT-URI (preserves rkey)", () => {
    const uri = "at://did:plc:abc/site.standard.document/foo%3Abar";
    expect(normalizeAtRepoParam(uri)).toBe(uri);
    expect(parseAtUri(uri)?.rkey).toBe("foo%3Abar");
  });

  it("still unwraps URL-encoded AT-URI path segments for route params", () => {
    const encoded =
      "at%3A%2F%2Fdid%3Aplc%3Aabc%2Fsite.standard.publication%2Frkey1";
    const decoded = "at://did:plc:abc/site.standard.publication/rkey1";
    expect(normalizeAtRepoParam(encoded)).toBe(decoded);
    expect(parseAtUri(encoded)?.rkey).toBe("rkey1");
  });

  it("decodes an encoded DID in the AT-URI authority (single-layer segment encoding)", () => {
    const raw =
      "at://did%3Aplc%3Aabc7/site.standard.publication/rkey1";
    const canonical =
      "at://did:plc:abc7/site.standard.publication/rkey1";
    expect(normalizeAtRepoParam(raw)).toBe(canonical);
    expect(parseAtUri(raw)?.did).toBe("did:plc:abc7");
  });

  it("fully unwraps double-encoded DID segments inside at:// without touching rkey escapes", () => {
    const raw =
      "at://did%253Aplc%253Ax77/site.standard.document/foo%3Abar";
    const expected =
      "at://did:plc:x77/site.standard.document/foo%3Abar";
    expect(normalizeAtRepoParam(raw)).toBe(expected);
    expect(parseAtUri(raw)?.rkey).toBe("foo%3Abar");
  });
});

describe("readRoutePubIdFromSegments", () => {
  it("passes through a plain DID unchanged", () => {
    expect(readRoutePubIdFromSegments(["did:plc:x"])).toBe("did:plc:x");
    expect(readRoutePubIdFromSegments("did:plc:x")).toBe("did:plc:x");
  });

  it("joins multiple path segments produced by decoded slashes in publication AT-URIs", () => {
    expect(
      readRoutePubIdFromSegments([
        "at:",
        "",
        "did:plc:foo",
        "site.standard.publication",
        "rkey1",
      ])
    ).toBe("at://did:plc:foo/site.standard.publication/rkey1");
  });

  it("handles a single encoded-segment pathname shape", () => {
    const encoded =
      "at%3A%2F%2Fdid%3Aplc%3Aabc%2Fsite.standard.publication%2Frkey1";
    expect(readRoutePubIdFromSegments([encoded])).toBe(
      "at://did:plc:abc/site.standard.publication/rkey1"
    );
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

  it("derives repo DID from a publication AT-URI whose authority is still segment-encoded", () => {
    const encoded =
      "at://did%3Aplc%3Aabc/site.standard.publication/3lmn4op56qr7s";
    const canonical =
      "at://did:plc:abc/site.standard.publication/3lmn4op56qr7s";
    expect(repoAndPublicationFilterFromPubId(encoded)).toEqual({
      repoDid: "did:plc:abc",
      publicationAtUri: canonical,
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

describe("entryRecordMatchesPublication", () => {
  const pub =
    "at://did:plc:abc12/site.standard.publication/site-root";

  it("matches when site string matches exactly", () => {
    expect(
      entryRecordMatchesPublication({ site: pub }, pub)
    ).toBe(true);
  });

  it("matches when publication uses mixed-case did:plc and site is lowercase", () => {
    const mixedPub =
      "at://DID:PLC:ABC12/site.standard.publication/site-root";
    expect(entryRecordMatchesPublication({ site: pub }, mixedPub)).toBe(
      true
    );
  });

  it("matches when site is still authority-encoded but filter is canonical", () => {
    const encodedSite =
      "at://did%3Aplc%3Aabc12/site.standard.publication/site-root";
    expect(entryRecordMatchesPublication({ site: encodedSite }, pub)).toBe(
      true
    );
  });

  it("matches a com.atproto.repo.strongRef-shaped site field", () => {
    expect(
      entryRecordMatchesPublication(
        { site: { uri: pub, cid: "bafyx" } },
        pub
      )
    ).toBe(true);
  });

  it("matches com.standard.publication sidebar key when site points at site.standard.publication (mirror lexicons)", () => {
    const siteNs =
      "at://did:plc:abc12/site.standard.publication/site-root";
    const comNs =
      "at://did:plc:abc12/com.standard.publication/site-root";
    expect(
      entryRecordMatchesPublication({ site: siteNs }, comNs)
    ).toBe(true);
    expect(
      entryRecordMatchesPublication({ site: comNs }, siteNs)
    ).toBe(true);
  });

  it("is false for another publication rkey", () => {
    expect(
      entryRecordMatchesPublication(
        {
          site:
            "at://did:plc:abc12/site.standard.publication/other-site",
        },
        pub
      )
    ).toBe(false);
  });

  it("matches publicationUri field used by some standard.site publishers", () => {
    expect(
      entryRecordMatchesPublication(
        {
          publicationUri: pub,
          title: "Offprint post",
        },
        pub
      )
    ).toBe(true);
  });

  it("matches publication field alias", () => {
    expect(
      entryRecordMatchesPublication({ publication: pub }, pub)
    ).toBe(true);
  });

  it("matches when document site is the publication https url", () => {
    const match: PublicationScopeMatch = {
      atUriKeys: new Set([
        "at://did:plc:abc12/site.standard.publication/site-root",
        "at://did:plc:abc12/com.standard.publication/site-root",
      ]),
      siteUrlKeys: new Set(["https://news.offprint.app"]),
    };
    expect(
      entryRecordMatchesPublicationScope(
        { site: "https://news.offprint.app", title: "Post" },
        match
      )
    ).toBe(true);
  });

  it("matches documents tied to a sibling publication record with the same name", () => {
    const currentPub =
      "at://did:plc:author/site.standard.publication/new-offprint";
    const legacyPub =
      "at://did:plc:author/site.standard.publication/legacy-leaflet";
    const match: PublicationScopeMatch = {
      atUriKeys: new Set([
        currentPub,
        legacyPub,
        "at://did:plc:author/com.standard.publication/new-offprint",
        "at://did:plc:author/com.standard.publication/legacy-leaflet",
      ]),
      siteUrlKeys: new Set([
        "https://example.offprint.app",
        "https://example.leaflet.pub",
      ]),
    };
    expect(
      entryRecordMatchesPublicationScope(
        { site: legacyPub, title: "Older post" },
        match
      )
    ).toBe(true);
  });
});

describe("decodeListEntriesPageCursor", () => {
  it("treats empty as initial fetch", () => {
    expect(decodeListEntriesPageCursor(undefined)).toEqual({
      phase: "initial",
    });
    expect(decodeListEntriesPageCursor("")).toEqual({ phase: "initial" });
  });

  it("parses collection index plus optional PDS listRecords cursor", () => {
    expect(
      decodeListEntriesPageCursor(
        `2:${encodeURIComponent("next-cursor/token")}`
      )
    ).toEqual({
      phase: "page",
      colIdx: 2,
      atproto: "next-cursor/token",
    });
  });

  it("maps legacy d: and e: collection shims", () => {
    expect(decodeListEntriesPageCursor("d:tok")).toEqual({
      phase: "page",
      colIdx: 0,
      atproto: "tok",
    });
    expect(decodeListEntriesPageCursor("e:tok")).toEqual({
      phase: "page",
      colIdx: 2,
      atproto: "tok",
    });
  });

  it("passes through a bare token as collection 0 (older clients)", () => {
    expect(decodeListEntriesPageCursor("opaque-cursor")).toEqual({
      phase: "page",
      colIdx: 0,
      atproto: "opaque-cursor",
    });
  });
});

describe("decodePublicationScopeListCursor", () => {
  it("round-trips publication-scope cursors with skip offset", () => {
    const encoded = `p|2|${encodeURIComponent("pds-cursor")}|7`;
    expect(decodePublicationScopeListCursor(encoded)).toEqual({
      colIdx: 2,
      atproto: "pds-cursor",
      matchSkip: 7,
    });
  });

  it("defaults when cursor is missing or uses wrong prefix", () => {
    expect(decodePublicationScopeListCursor(undefined)).toEqual({
      colIdx: 0,
      matchSkip: 0,
    });
    expect(decodePublicationScopeListCursor("0:bad")).toEqual({
      colIdx: 0,
      matchSkip: 0,
    });
  });
});

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
