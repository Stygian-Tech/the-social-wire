import { describe, expect, it } from "bun:test";
import {
  legacyHexEntryReadStateRkey,
  legacyIOSLatrExternalRkey,
  isLegacyHexReadStateRkey,
  isLegacyLatrExternalRkey,
} from "@/lib/legacyRecordKeys";

describe("legacyRecordKeys", () => {
  it("detects legacy iOS external rkeys", async () => {
    const canonical = "MMSTQKIENDT2HHAGGI6J4OXJR4YQOLLEDS5TP2RXSF7VNO7LKU4Q";
    const legacy = await legacyIOSLatrExternalRkey("https://example.com/article");
    expect(isLegacyLatrExternalRkey(canonical, legacy)).toBe(true);
    expect(legacy).toBe("mmstqkiendt2hhaggi6j4oxjr4yqolleds5tp2rxsf7vno7lku4q");
  });

  it("detects legacy hex read-state rkeys", async () => {
    const legacy = await legacyHexEntryReadStateRkey(
      "at://did:plc:alice/site.standard.document/abc123"
    );
    expect(isLegacyHexReadStateRkey(legacy)).toBe(true);
    expect(legacy).toBe(
      "4bca04db28cfeb6827628e97f791f16e439f2d3f6294edc5560fb9a097dc686f"
    );
  });
});
