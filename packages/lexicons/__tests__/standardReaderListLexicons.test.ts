import { describe, expect, test } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// Mirrors the published schemas at https://standard-reader.app/docs/lexicons.
const read = (name: string) => JSON.parse(readFileSync(join(import.meta.dir, "../app/standard-reader", `${name}.json`), "utf8"));
const listSchema = read("list");
const saveSchema = read("listSave");
const lexicons = new Lexicons([listSchema, saveSchema]);
const createdAt = "2026-10-02T12:00:00Z";
const uri = "at://did:plc:creator/app.standard-reader.list/3moc2s6xjao2q";
const list = { $type: listSchema.id, name: "Reading", publications: ["at://did:plc:creator/site.standard.publication/3moc2s6xjao2q"], users: ["did:plc:author"], createdAt };

describe("Standard Reader external list contracts", () => {
  test("retains upstream identity, record keys, required fields and optional authors", () => {
    expect(listSchema.id).toBe("app.standard-reader.list");
    expect(listSchema.defs.main.key).toBe("tid");
    expect(saveSchema.defs.main.key).toBe("any");
    expect(listSchema.defs.main.record.required).toEqual(["name", "publications", "createdAt"]);
    expect(saveSchema.defs.main.record.required).toEqual(["list", "createdAt"]);
    expect(() => lexicons.assertValidRecord(listSchema.id, list)).not.toThrow();
    expect(() => lexicons.assertValidRecord(listSchema.id, { ...list, publications: [], users: ["did:plc:author"] })).not.toThrow();
    expect(() => lexicons.assertValidRecord(listSchema.id, { ...list, users: undefined })).not.toThrow();
  });
  test("enforces ordered member array bounds and reference formats", () => {
    for (const invalid of [{ publications: Array(501).fill(list.publications[0]) }, { users: Array(501).fill("did:plc:author") }, { publications: ["https://example.com"] }, { users: ["creator.example"] }]) {
      expect(() => lexicons.assertValidRecord(listSchema.id, { ...list, ...invalid })).toThrow();
    }
  });
  test("bounds names and descriptions by UTF8 bytes and graphemes", () => {
    for (const invalid of [{ name: "a".repeat(65) }, { name: "👨‍👩‍👧‍👦".repeat(26) }, { description: "a".repeat(301) }, { createdAt: "today" }]) {
      expect(() => lexicons.assertValidRecord(listSchema.id, { ...list, ...invalid })).toThrow();
    }
    expect(() => lexicons.assertValidRecord(listSchema.id, { ...list, name: "e\u0301".repeat(64) })).not.toThrow();
  });
  test("save records contain only the public reference and timestamp", () => {
    expect(Object.keys(saveSchema.defs.main.record.properties)).toEqual(["list", "createdAt"]);
    expect(() => lexicons.assertValidRecord(saveSchema.id, { $type: saveSchema.id, list: uri, createdAt })).not.toThrow();
    for (const value of [{ list: "https://example.com", createdAt }, { list: uri, createdAt: "invalid" }, { list: uri }]) {
      expect(() => lexicons.assertValidRecord(saveSchema.id, { $type: saveSchema.id, ...value })).toThrow();
    }
  });
});
