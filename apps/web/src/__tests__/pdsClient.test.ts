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
  COLLECTION_STANDARD_SITE_SUBSCRIPTION,
  COLLECTION_LATR_SAVED_EXTERNAL,
  COLLECTION_LATR_SAVED_ITEM,
  COLLECTION_SKYREADER_FEED_SUBSCRIPTION,
  mergeExternalsAndItemsToHttpsRows,
  type LatrSavedExternalRecord,
  type LatrSavedItemRecord,
  PSEUDO_FOLDER_HIDDEN_URI,
  PSEUDO_FOLDER_MY_URI,
} from "@/lib/pdsClient";

describe("rkeyFromURI", () => {
  it("extracts rkey from an at-uri", () => {
    const uri = "at://did:plc:alice123/com.thesocialwire.folder/3lmn4op56qr7s";
    expect(rkeyFromURI(uri)).toBe("3lmn4op56qr7s");
  });

  it("returns the input if there is no slash", () => {
    expect(rkeyFromURI("justanrkey")).toBe("justanrkey");
  });

  it("handles at-uri for publicationPrefs", () => {
    const uri = `at://did:plc:bob/com.thesocialwire.publicationPrefs/abc123`;
    expect(rkeyFromURI(uri)).toBe("abc123");
  });
});

describe("collection constants", () => {
  it("folder collection ID matches lexicon", () => {
    expect(COLLECTION_FOLDER).toBe("com.thesocialwire.folder");
  });

  it("publicationPrefs collection ID matches lexicon", () => {
    expect(COLLECTION_PUB_PREFS).toBe("com.thesocialwire.publicationPrefs");
  });

  it("preferences collection ID matches lexicon", () => {
    expect(COLLECTION_PREFERENCES).toBe("com.thesocialwire.preferences");
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

  it("hidden pseudo-folder URI is stable", () => {
    expect(PSEUDO_FOLDER_HIDDEN_URI).toBe("__hidden__");
    expect(rkeyFromURI(PSEUDO_FOLDER_HIDDEN_URI)).toBe(PSEUDO_FOLDER_HIDDEN_URI);
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
});
