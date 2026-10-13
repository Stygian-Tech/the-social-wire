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

const sportsSource = JSON.parse(readFileSync(join(root, "app/thesocialwire/corpus/getSportsGeneration.json"), "utf8"));
const sportsLexicons = new Lexicons([sportsSource, defs, shared]);
describe("internal Sports source lexicon", () => {
  it("defines bounded typed candidates and exact canonical catalog metadata", () => {
    expect(sportsSource.defs.main.type).toBe("procedure");
    expect(sportsSource.defs.main.output.schema.properties.candidates.maxLength).toBe(5000);
    expect(sportsSource.defs.main.output.schema.properties).not.toHaveProperty("catalog");
    expect(sportsSource.defs.main.output.schema.required).toContain("servingCatalogRevision");
    expect(sportsSource.defs.candidate.properties).not.toHaveProperty("summary");
    expect(sportsSource.defs.candidate.properties.presentationFingerprint.maxLength).toBe(64);
    expect(() => sportsLexicons.assertValidXrpcInput(sportsSource.id, { language: "en" })).not.toThrow();
    for (const input of [{}, { language: "" }, { language: "a".repeat(36) }, { language: "en", knownGenerationRevision: "a".repeat(65) }]) {
      expect(() => sportsLexicons.assertValidXrpcInput(sportsSource.id, input)).toThrow();
    }
  });
  it("requires exact generation revision and preserves explicit conditional markers", () => {
    const response = { generationId: "11111111-1111-1111-1111-111111111111", generationRevision: "a".repeat(64), generatedAt: "2026-10-12T00:00:00Z", expiresAt: "2026-10-13T00:00:00Z", language: "en", resolverVersion: "sports-resolver-v14", catalogRevision: "b".repeat(64), servingCatalogRevision: "b".repeat(64), catalogVersion: "version", catalogGeneratedAt: "2026-10-12T00:00:00.123456Z", generationUnchanged: true };
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, response)).not.toThrow();
    const { generationRevision, ...missingRevision } = response;
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, missingRevision)).toThrow();
  });
});
