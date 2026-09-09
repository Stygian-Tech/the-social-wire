import { expect, test } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const docs = ["readState", "readStateChunk", "readStateDefs"].map((name) =>
  JSON.parse(readFileSync(join(import.meta.dir, `../app/thesocialwire/${name}.json`), "utf8"))
);
const strongRef = { lexicon: 1, id: "com.atproto.repo.strongRef", defs: { main: {
  type: "object", required: ["uri", "cid"], properties: {
    uri: { type: "string", format: "at-uri" }, cid: { type: "string", format: "cid" },
  },
} } };
const lexicons = new Lexicons([strongRef, ...docs]);

test("manifest schema requires bounded committed sequence and singleton key", () => {
  expect(docs[0].defs.main.key).toBe("literal:self");
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readState", {
    $type: "app.thesocialwire.readState", version: 1, generation: "g", lastSequence: 0,
  })).not.toThrow();
  for (const lastSequence of [-1, 9007199254740992]) {
    expect(() => lexicons.assertValidRecord("app.thesocialwire.readState", {
      $type: "app.thesocialwire.readState", version: 1, generation: "g", lastSequence,
    })).toThrow();
  }
});

test("chunk schema carries explicit unread and exact sets without per-item repo writes", () => {
  const operation = { actionId: "one", sequence: 1, state: "unread", actedAt: "2026-09-08T12:00:00Z",
    selection: "exact", subjectUris: ["at://did:plc:example/site.standard.document/a"] };
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    $type: "app.thesocialwire.readStateChunk", version: 1, operations: [operation],
  })).not.toThrow();
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    $type: "app.thesocialwire.readStateChunk", version: 1, operations: [{ ...operation, state: "delete" }],
  })).toThrow();
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    $type: "app.thesocialwire.readStateChunk", version: 1,
    operations: [{ ...operation, subjectUris: Array.from({ length: 257 }, (_, i) => `item${i}`) }],
  })).toThrow();
});

test("v2 separates maintenance revisions and bounds state and receipt chunks", () => {
  const manifest = { $type: "app.thesocialwire.readState", version: 2, generation: "v2",
    revision: 2, lastSequence: 1, compactionVersion: 1 };
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readState", manifest)).not.toThrow();
  for (const revision of [-1, 9007199254740992]) {
    expect(() => lexicons.assertValidRecord("app.thesocialwire.readState", { ...manifest, revision })).toThrow();
  }
  const fragment = { fragment: true, intentHash: "a".repeat(64), actionId: "one", sequence: 1,
    state: "unread", actedAt: "2026-09-08T12:00:00Z", selection: "exact", subjectUris: ["x"],
    deviceId: "device-a", deviceCounter: 1 };
  const chunk = { $type: "app.thesocialwire.readStateChunk", version: 2, kind: "state", fragments: [fragment] };
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", chunk)).not.toThrow();
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    ...chunk, fragments: Array.from({ length: 129 }, () => fragment),
  })).toThrow();
  const receipt = { deviceId: "device-a", committedCounter: 1, prefixHash: "b".repeat(64) };
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    $type: "app.thesocialwire.readStateChunk", version: 2, kind: "devices", receipts: [receipt],
  })).not.toThrow();
  expect(() => lexicons.assertValidRecord("app.thesocialwire.readStateChunk", {
    $type: "app.thesocialwire.readStateChunk", version: 2, kind: "devices",
    receipts: Array.from({ length: 129 }, () => receipt),
  })).toThrow();
});
