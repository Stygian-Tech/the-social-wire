import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import {
  latrExternalRkeyFromNormalizedUrl,
  latrFingerprintFromNormalizedUrl,
  latrItemRkeyFromSubjectUri,
  normalizeLatrHttpsUrl,
} from "@/lib/latrSavedUrls";

const latrPackagesRoot = join(import.meta.dir, "../../../../node_modules/latr-packages");

const golden = JSON.parse(
  readFileSync(
    join(
      latrPackagesRoot,
      "packages/record-keys/fixtures/stygian-golden-vectors.v1.json"
    ),
    "utf8"
  )
).vectors;

describe("stygian golden vectors — L@tr/read-state keys", () => {
  it("entryReadStateRkey matches canonical base32", async () => {
    const rkey = await latrItemRkeyFromSubjectUri(
      golden.entryReadStateRkey.input
    );
    expect(rkey).toBe(golden.entryReadStateRkey.canonical);
  });

  it("latrExternalRkey matches canonical base32", async () => {
    const rkey = await latrExternalRkeyFromNormalizedUrl(
      golden.latrExternalRkey.normalizedUrl
    );
    expect(rkey).toBe(golden.latrExternalRkey.canonical);
  });

  it("latrFingerprint matches sha256 hex", async () => {
    const fp = await latrFingerprintFromNormalizedUrl(
      golden.latrFingerprint.normalizedUrl
    );
    expect(fp).toBe(golden.latrFingerprint.sha256Hex);
  });
});

describe("stygian golden vectors — URL normalization", () => {
  for (const case_ of golden.normalizeLatrHttpsUrl) {
    it(`normalizes ${case_.input}`, () => {
      expect(normalizeLatrHttpsUrl(case_.input)).toBe(case_.output);
    });
  }
});

describe("stygian golden vectors — latr item rkey for external wrapper", () => {
  it("derives item rkey from canonical external AT-URI", async () => {
    const externalUri = `at://did:plc:me/com.latr.saved.external/${golden.latrExternalRkey.canonical}`;
    const itemRkey = await latrItemRkeyFromSubjectUri(externalUri);
    expect(itemRkey).toMatch(/^[A-Z2-7]+$/);
    expect(itemRkey.length).toBeGreaterThan(50);
  });
});
