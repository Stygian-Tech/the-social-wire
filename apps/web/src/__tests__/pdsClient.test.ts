/**
 * Unit tests for lib/pdsClient.ts
 *
 * Tests the record shaping logic and helpers.
 * PDSClient XRPC calls are not tested here (they require a running PDS);
 * those are integration tests.
 */

import { describe, it, expect } from "bun:test";
import { rkeyFromURI, COLLECTION_FOLDER, COLLECTION_PUB_PREFS } from "@/lib/pdsClient";

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
});
