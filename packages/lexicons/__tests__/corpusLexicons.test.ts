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
    expect(sportsSource.defs.main.output.schema.properties.candidates.description).toContain("presentationFingerprint");
    expect(() => sportsLexicons.assertValidXrpcInput(sportsSource.id, { language: "en" })).not.toThrow();
    for (const input of [{}, { language: "" }, { language: "a".repeat(36) }, { language: "en", knownGenerationRevision: "a".repeat(65) }]) {
      expect(() => sportsLexicons.assertValidXrpcInput(sportsSource.id, input)).toThrow();
    }
  });
  it("requires exact generation revision and preserves explicit conditional markers", () => {
    const response = { generationId: "11111111-1111-1111-1111-111111111111", generationRevision: "a".repeat(64), generatedAt: "2026-10-12T00:00:00Z", expiresAt: "2026-10-13T00:00:00Z", language: "en", resolverVersion: "sports-resolver-v14", catalogRevision: "b".repeat(64), servingCatalogRevision: "b".repeat(64), catalogVersion: "version", catalogGeneratedAt: "2026-10-12T00:00:00.123456Z", generationUnchanged: true };
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, response)).not.toThrow();
    const candidate = { itemId: "story", canonicalUrl: "https://example.com/story", title: "Sports", domain: "example.com", presentationFingerprint: "c".repeat(64), analysis: { resolverVersion: "sports-resolver-v14", eligible: true, materiality: "championship", associations: [{ entityID: "team", confidence: 0.95, prominence: 1, evidence: ["headline"], resolverVersion: "sports-resolver-v14" }], sportIDs: [], competitionIDs: [] }, baseScore: 1.25, majorGlobal: false };
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, { ...response, generationUnchanged: false, candidates: [candidate] })).not.toThrow();
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, { ...response, candidates: [1.25] })).toThrow();
    const { generationRevision, ...missingRevision } = response;
    expect(() => sportsLexicons.assertValidXrpcOutput(sportsSource.id, missingRevision)).toThrow();
  });
});

const financeSource = JSON.parse(readFileSync(join(root, "app/thesocialwire/corpus/getFinanceGeneration.json"), "utf8"));
const financeLexicons = new Lexicons([financeSource, defs, shared]);
describe("internal conditional Finance source lexicon", () => {
  it("requires current metadata and defines the unchanged full presentation contract", () => {
    expect(financeSource.defs.main.type).toBe("procedure");
    expect(financeSource.defs.main.output.schema.properties.generation.description).toContain("5,000");
    expect(financeSource.defs.main.output.schema.properties.generation.ref.endsWith("app.thesocialwire.defs#jsonObject")).toBe(true);
    expect(() => financeLexicons.assertValidXrpcInput(financeSource.id, { language: "en" })).not.toThrow();
    for (const input of [{}, { language: "" }, { language: "en", knownGenerationRevision: "a".repeat(65) }]) {
      expect(() => financeLexicons.assertValidXrpcInput(financeSource.id, input)).toThrow();
    }
    const metadata = { generationId: "22222222-1111-1111-1111-111111111111", generationRevision: "a".repeat(64), generatedAt: "2026-10-12T00:00:00Z", expiresAt: "2026-10-13T00:00:00Z", language: "en", generationUnchanged: true };
    expect(() => financeLexicons.assertValidXrpcOutput(financeSource.id, metadata)).not.toThrow();
    const { generationRevision, ...missingRevision } = metadata;
    expect(() => financeLexicons.assertValidXrpcOutput(financeSource.id, missingRevision)).toThrow();
    const generation = { generationId: metadata.generationId, generatedAt: metadata.generatedAt, expiresAt: metadata.expiresAt, language: "en", candidates: [{ item: { itemId: "story", title: "Finance", canonicalUrl: "https://example.com/story", source: { name: "Example", domain: "example.com" }, reasons: [], provenance: [] }, analysis: { resolverVersion: "finance-resolver-v3.4", eligible: true, materiality: "earnings", associations: [], sectorIDs: [] }, baseScore: 1, majorGlobal: false }], instruments: [] };
    expect(() => financeLexicons.assertValidXrpcOutput(financeSource.id, { ...metadata, generationUnchanged: false, generation })).not.toThrow();
    expect(() => financeLexicons.assertValidXrpcOutput(financeSource.id, { ...metadata, generation: "invalid" })).toThrow();
  });
});
