/**
 * Unit tests for lib/pdsClient.ts
 *
 * Tests the record shaping logic and helpers.
 * PDSClient XRPC calls are not tested here (they require a running PDS);
 * those are integration tests.
 */

import { describe, it, expect } from "bun:test";
import {
  rkeyFromURI,
  COLLECTION_FOLDER,
  COLLECTION_PUB_PREFS,
  COLLECTION_PREFERENCES,
  LEGACY_COLLECTION_FOLDER,
  LEGACY_COLLECTION_PUB_PREFS,
  LEGACY_COLLECTION_PREFERENCES,
  LEGACY_COLLECTION_ENTRY_READ_STATE,
  COLLECTION_STANDARD_SITE_SUBSCRIPTION,
  COLLECTION_LATR_SAVED_EXTERNAL,
  COLLECTION_LATR_SAVED_ITEM,
  COLLECTION_ENTRY_READ_STATE,
  COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
  mergeExternalsAndItemsToHttpsRows,
  mergedLatrSavesFromGatewayItems,
  filterMergedLatrSavesByState,
  entryReadStateRkeyFromSubjectUri,
  type LatrSavedExternalRecord,
  type LatrSavedItemRecord,
  PSEUDO_FOLDER_MY_URI,
} from "@/lib/pdsClient";

describe("rkeyFromURI", () => {
  it("extracts rkey from an at-uri", () => {
    const uri = "at://did:plc:alice123/app.thesocialwire.folder/3lmn4op56qr7s";
    expect(rkeyFromURI(uri)).toBe("3lmn4op56qr7s");
  });

  it("returns the input if there is no slash", () => {
    expect(rkeyFromURI("justanrkey")).toBe("justanrkey");
  });

  it("handles at-uri for publicationPrefs", () => {
    const uri = `at://did:plc:bob/app.thesocialwire.publicationPrefs/abc123`;
    expect(rkeyFromURI(uri)).toBe("abc123");
  });
});

describe("collection constants", () => {
  it("folder collection ID matches lexicon", () => {
    expect(COLLECTION_FOLDER).toBe("app.thesocialwire.folder");
  });

  it("publicationPrefs collection ID matches lexicon", () => {
    expect(COLLECTION_PUB_PREFS).toBe("app.thesocialwire.publicationPrefs");
  });

  it("preferences collection ID matches lexicon", () => {
    expect(COLLECTION_PREFERENCES).toBe("app.thesocialwire.preferences");
  });

  it("legacy folder collection ID is preserved for migration", () => {
    expect(LEGACY_COLLECTION_FOLDER).toBe("com.thesocialwire.folder");
  });

  it("legacy publicationPrefs collection ID is preserved for migration", () => {
    expect(LEGACY_COLLECTION_PUB_PREFS).toBe(
      "com.thesocialwire.publicationPrefs"
    );
  });

  it("legacy preferences collection ID is preserved for migration", () => {
    expect(LEGACY_COLLECTION_PREFERENCES).toBe("com.thesocialwire.preferences");
  });

  it("legacy entryReadState collection ID is preserved for migration", () => {
    expect(LEGACY_COLLECTION_ENTRY_READ_STATE).toBe(
      "com.thesocialwire.entryReadState"
    );
  });

  it("standard.site subscription collection ID matches lexicon", () => {
    expect(COLLECTION_STANDARD_SITE_SUBSCRIPTION).toBe(
      "site.standard.graph.subscription"
    );
  });

  it("Skyreader subscription collection mirrors upstream lexicon", () => {
    expect(COLLECTION_SKYREADER_FEED_SUBSCRIPTION).toBe(
      "app.skyreader.feed.subscription"
    );
  });

  it("entryReadState collection ID matches lexicon", () => {
    expect(COLLECTION_ENTRY_READ_STATE).toBe(
      "app.thesocialwire.entryReadState"
    );
  });

  it("my pseudo-folder URI is stable", () => {
    expect(PSEUDO_FOLDER_MY_URI).toBe("__my__");
    expect(rkeyFromURI(PSEUDO_FOLDER_MY_URI)).toBe(PSEUDO_FOLDER_MY_URI);
  });
});

describe("mergeExternalsAndItemsToHttpsRows", () => {
  const did = "did:plc:testuser";

  const extUri = `at://${did}/${COLLECTION_LATR_SAVED_EXTERNAL}/EXTKEYXYZ`;
  const external: LatrSavedExternalRecord = {
    $type: COLLECTION_LATR_SAVED_EXTERNAL,
    url: "https://example.com/foo?utm_source=x",
    normalizedUrl: "https://example.com/foo",
    fingerprint: "abc",
    createdAt: "2026-01-01T00:00:00.000Z",
    title: "Example",
  };

  it("pairs an item subject with its external wrapper and keeps newest queued save only", () => {
    const externals = [{ uri: extUri, cid: "cid1", value: external }];
    const items = [
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/itemOld`,
        cid: "ci",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri: extUri,
          savedAt: "2026-01-01T00:00:00.000Z",
        } satisfies LatrSavedItemRecord,
      },
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/itemNew`,
        cid: "ci2",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri: extUri,
          savedAt: "2026-06-01T12:00:00.000Z",
        } satisfies LatrSavedItemRecord,
      },
    ];

    const rows = mergeExternalsAndItemsToHttpsRows(externals, items);
    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe("external");
    expect(rows[0].savedAt).toBe("2026-06-01T12:00:00.000Z");
    if (rows[0].kind !== "external") throw new Error("Expected external row");
    expect(rows[0].externalRkey).toBe("EXTKEYXYZ");
    expect(rows[0].normalizedUrl).toBe("https://example.com/foo");
  });

  it("keeps items whose subjects are native ATProto records", () => {
    const externals = [{ uri: extUri, cid: "cid1", value: external }];
    const subjectUri = `at://${did}/app.bsky.feed.post/native`;
    const items = [
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/native`,
        cid: "cx",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri,
          savedAt: "2026-06-01T12:00:00.000Z",
        } satisfies LatrSavedItemRecord,
      },
    ];
    const rows = mergeExternalsAndItemsToHttpsRows(externals, items);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      kind: "native",
      itemRkey: "native",
      subjectUri,
    });
  });

  it("preserves item state on merged rows", () => {
    const externals = [{ uri: extUri, cid: "cid1", value: external }];
    const items = [
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/archived`,
        cid: "cx",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri: extUri,
          savedAt: "2026-06-01T12:00:00.000Z",
          state: "archived",
        } satisfies LatrSavedItemRecord,
      },
    ];

    expect(mergeExternalsAndItemsToHttpsRows(externals, items)[0].state).toBe(
      "archived"
    );
  });

  it("merges external metadata with item preview fallbacks", () => {
    const externals = [
      {
        uri: extUri,
        cid: "cid1",
        value: {
          ...external,
          site: "example.com",
          author: "Jane",
          image: "https://example.com/thumb.jpg",
        },
      },
    ];
    const items = [
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/item1`,
        cid: "cx",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri: extUri,
          savedAt: "2026-06-01T12:00:00.000Z",
          previewExcerpt: "Preview excerpt",
        } satisfies LatrSavedItemRecord,
      },
    ];

    const row = mergeExternalsAndItemsToHttpsRows(externals, items)[0];
    expect(row.kind).toBe("external");
    if (row.kind !== "external") throw new Error("Expected external row");
    expect(row.site).toBe("example.com");
    expect(row.author).toBe("Jane");
    expect(row.image).toBe("https://example.com/thumb.jpg");
    expect(row.excerpt).toBe("Preview excerpt");
  });
});

describe("filterMergedLatrSavesByState", () => {
  const did = "did:plc:testuser";
  const extUri = `at://${did}/${COLLECTION_LATR_SAVED_EXTERNAL}/EXTKEYXYZ`;

  function row(state?: "unread" | "archived") {
    return {
      kind: "external" as const,
      normalizedUrl: "https://example.com/foo",
      url: "https://example.com/foo",
      savedAt: "2026-06-01T12:00:00.000Z",
      externalRkey: "EXTKEYXYZ",
      itemRkey: "item1",
      externalUri: extUri,
      itemUri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/item1`,
      subjectUri: extUri,
      ...(state ? { state } : {}),
    };
  }

  it("returns active rows when state is missing or unread", () => {
    const rows = [row(), row("unread"), row("archived")];
    expect(filterMergedLatrSavesByState(rows, "active")).toHaveLength(2);
  });

  it("returns only archived rows for archived filter", () => {
    const rows = [row(), row("archived")];
    expect(filterMergedLatrSavesByState(rows, "archived")).toEqual([
      row("archived"),
    ]);
  });
});

describe("mergedLatrSavesFromGatewayItems", () => {
  const did = "did:plc:testuser";
  const extUri = `at://${did}/${COLLECTION_LATR_SAVED_EXTERNAL}/EXTKEYXYZ`;

  it("builds external rows from item preview fields without listing externals on PDS", () => {
    const rows = mergedLatrSavesFromGatewayItems([
      {
        uri: `at://${did}/${COLLECTION_LATR_SAVED_ITEM}/item1`,
        cid: "cid",
        value: {
          $type: COLLECTION_LATR_SAVED_ITEM,
          subjectUri: extUri,
          savedAt: "2026-06-01T12:00:00.000Z",
          linkedWebUrl: "https://example.com/foo",
          previewTitle: "Example",
        },
      },
    ]);

    expect(rows).toHaveLength(1);
    expect(rows[0].kind).toBe("external");
    if (rows[0].kind !== "external") throw new Error("Expected external row");
    expect(rows[0].normalizedUrl).toBe("https://example.com/foo");
    expect(rows[0].title).toBe("Example");
  });
});

describe("entryReadStateRkeyFromSubjectUri", () => {
  it("is stable for a given entry URI", async () => {
    const uri = "at://did:plc:alice/site.standard.document/entry1";
    const a = await entryReadStateRkeyFromSubjectUri(uri);
    const b = await entryReadStateRkeyFromSubjectUri(uri);
    expect(a).toBe(b);
    expect(a.length).toBeGreaterThan(10);
  });
});
