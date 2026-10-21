import { expect, test } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

const prefix = "app.thesocialwire.socialDraft.";
const root = join(import.meta.dir, "../app/thesocialwire/socialDraft");
const documents = readdirSync(root).filter((name) => name.endsWith(".json")).map((name) => JSON.parse(readFileSync(join(root, name), "utf8")));
const schemas = new Lexicons(documents);
const main = (name: string) => documents.find((doc) => doc.id === prefix + name).defs.main;
const defs = documents.find((doc) => doc.id === prefix + "defs").defs;

test("private social drafts expose six storage XRPC methods and the Gateway GIF file query", () => {
  expect(documents.filter((doc) => doc.defs.main).map((doc) => doc.id.slice(prefix.length)).sort()).toEqual([
    "deleteManifest", "getAttachment", "getGifFile", "getManifest", "putManifest", "reserveAttachment", "uploadAttachment",
  ]);
  for (const doc of documents.filter((doc) => doc.defs.main)) {
    expect(doc.defs.main.description).toContain("Authentication required");
    expect(doc.defs.main.description).toContain("Never publishes");
    expect(doc.defs.main.errors.map((error: any) => error.name)).toEqual(expect.arrayContaining(doc.id === prefix + "getGifFile" ? ["Unauthorized", "Unavailable", "Quota"] : ["Unauthorized", "Unavailable", "Conflict", "Quota"]));
    expect(JSON.stringify(doc)).not.toContain('"did"');
    expect(JSON.stringify(doc)).not.toContain('"url"');
  }
});

test("binary transfers explicitly document private headers and bounds", () => {
  expect(main("uploadAttachment").input).toEqual({ encoding: "application/octet-stream" });
  expect(main("uploadAttachment").description).toContain("X-Social-Draft-Upload-Id");
  expect(main("uploadAttachment").description).toContain("104857600");
  expect(main("getAttachment").output).toEqual({ encoding: "*/*" });
  expect(main("getAttachment").description).toContain("private, no-store");
});

test("manifests preserve concurrency and enriched attachment bindings", () => {
  expect(main("putManifest").input.schema.required).toEqual(["draftId", "expectedRevision", "attachments"]);
  expect(main("deleteManifest").input.schema.required).toEqual(["draftId", "expectedRevision"]);
  expect(defs.manifest.required).toEqual(["draftId", "revision", "deleted", "attachments"]);
  expect(defs.assetBinding.required).toEqual(["assetId", "role", "ref", "asset"]);
  const asset = { assetId: "00000000-0000-0000-0000-000000000001", name: "photo.jpg", contentType: "image/jpeg", byteLength: 3, sha256: "0".repeat(64), kind: "photo", state: "ready" };
  const manifest = { draftId: "3m5abcdefghij", revision: 1, deleted: false, attachments: [{ assetId: asset.assetId, role: "original", ref: "", asset }] };
  expect(() => schemas.assertValidXrpcOutput(prefix + "getManifest", manifest)).not.toThrow();
  expect(() => schemas.assertValidXrpcOutput(prefix + "getManifest", { ...manifest, revision: -1 })).toThrow();
  expect(() => schemas.assertValidXrpcOutput(prefix + "reserveAttachment", { attachment: { ...asset, byteLength: 104857601 } })).toThrow();
});


test("Gateway GIF copies require an exact catalog ID and explicit rendition", () => {
  const gif = main("getGifFile");
  expect(gif.parameters.required).toEqual(["id", "rendition"]);
  expect(Object.keys(gif.parameters.properties)).toEqual(["id", "rendition"]);
  expect(gif.parameters.properties.rendition.enum).toEqual(["gif", "poster", "mp4", "webm"]);
  expect(gif.output.encoding).toBe("*/*");
  expect(gif.description).toContain("Gateway-only");
  expect(gif.description).toContain("no input URLs, redirects, or alternate-file fallback");
});


test("retired reservation IDs have a distinct error from metadata and revision conflicts", () => {
  expect(main("reserveAttachment").errors.map((error: any) => error.name)).toContain("AssetRetired");
  expect(main("reserveAttachment").errors.map((error: any) => error.name)).toContain("Conflict");
  expect(main("putManifest").errors.map((error: any) => error.name)).toContain("Conflict");
  expect(main("putManifest").errors.map((error: any) => error.name)).not.toContain("AssetRetired");
});
