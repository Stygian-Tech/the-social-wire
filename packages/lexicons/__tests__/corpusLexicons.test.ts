import { describe, expect, it } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const root = join(import.meta.dir, "..");
const schema = JSON.parse(readFileSync(join(root, "app/thesocialwire/corpus/getItems.json"), "utf8"));
const defs = JSON.parse(readFileSync(join(root, "app/thesocialwire/discovery/defs.json"), "utf8"));
const shared = JSON.parse(readFileSync(join(root, "app/thesocialwire/defs.json"), "utf8"));
const lexicons = new Lexicons([schema, defs, shared]);

describe("internal corpus batch lexicon", () => {
  it("bounds request batches to 100 nonempty item identifiers", () => {
    expect(schema.defs.main.type).toBe("procedure");
    expect(schema.defs.main.errors.map((error: { name: string }) => error.name)).toEqual(["InvalidRequest", "Unauthorized", "ModerationUnavailable", "UpstreamUnavailable", "InternalServerError"]);
    expect(() => lexicons.assertValidXrpcInput(schema.id, { itemIds: ["a"] })).not.toThrow();
    expect(() => lexicons.assertValidXrpcInput(schema.id, { itemIds: Array.from({ length: 100 }, (_, i) => `item-${i}`) })).not.toThrow();
    for (const input of [{}, { itemIds: [] }, { itemIds: [""] }, { itemIds: ["a".repeat(129)] }, { itemIds: Array.from({ length: 101 }, (_, i) => `item-${i}`) }]) {
      expect(() => lexicons.assertValidXrpcInput(schema.id, input)).toThrow();
    }
  });

  it("allows missing current items to be omitted while retaining source identity for local moderation", () => {
    expect(() => lexicons.assertValidXrpcOutput(schema.id, { items: {} })).not.toThrow();
    expect(schema.defs.item.properties.sourceActorKey.type).toBe("string");
    expect(schema.defs.item.required).not.toContain("sourceActorKey");
    expect(() => lexicons.assertValidXrpcOutput(schema.id, {})).toThrow();
  });
});
