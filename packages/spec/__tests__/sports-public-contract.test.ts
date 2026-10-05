import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const root = join(import.meta.dir, "../../..");
const lexicon = (path: string) => JSON.parse(readFileSync(join(root, "packages/lexicons/app/thesocialwire", path), "utf8"));
describe("Sports public contract", () => {
  test("catalog abbreviations remain optional bounded explicit metadata", () => {
    const entity = lexicon("discovery/defs.json").defs.sportsEntity;
    expect(entity.required).not.toContain("abbreviation");
    expect(entity.properties.abbreviation.minLength).toBe(2);
    expect(entity.properties.abbreviation.maxLength).toBe(8);
    const openapi = readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8");
    expect(openapi).toContain('abbreviation: { type: string, minLength: 2, maxLength: 8, pattern: "^[A-Z0-9]{2,8}$" }');
  });

  test("publishes matching-only catalog feeds and context-bound continuation inputs", () => {
    const query = lexicon("discovery/getSports.json").defs.main;
    expect(query.parameters.properties.feed.default).toBe("sports");
    expect(query.parameters.properties.limit.maximum).toBe(50);
    expect(query.errors.some((error: { name: string }) => error.name === "CursorExpired")).toBe(true);
    const defs = lexicon("discovery/defs.json").defs;
    expect(defs.sportsPage.required).toContain("preferenceRevision");
    expect(defs.sportsItem.required).toContain("sportIDs");
    expect(defs.sportsItem.required).toContain("competitionIDs");
    expect(defs.sportsAvailability.required).toContain("eventsEnabled");
  });
  test("optional schedule and standings context retains provider coverage and freshness", () => {
    const defs = lexicon("discovery/defs.json").defs;
    expect(defs.sportsEvents.properties.standings.items.ref).toEndWith("#sportsStandingSnapshot");
    expect(defs.sportsEvents.properties.schedulesStatus.knownValues).toEqual(["available", "empty", "unavailable"]);
    expect(defs.sportsStandingSnapshot.required).toContain("degraded");
    expect(defs.sportsStandingSnapshot.properties.rows.maxLength).toBe(3000);
    expect(defs.sportsStandingRow.properties.points.type).toBe("string");
    expect(defs.sportsStandingRow.properties.zone.ref).toEndWith("#sportsStandingZone");
    expect(defs.sportsStandingZone.required).toEqual(["kind", "label", "sourceURL"]);
    const api = readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8");
    expect(api).toContain('"#/components/schemas/SportsStandingSnapshot"');
    expect(api).toContain("schedulesStatus: { type: string, enum: [available, empty, unavailable] }");
  });
  test("one public entity record supports follow or mute without private profile data", () => {
    const main = lexicon("sports/selection.json").defs.main;
    expect(main.record.properties.action.enum).toEqual(["follow", "mute"]);
    expect(main.description).toContain("SHA-256(canonical reference)");
    expect(Object.keys(main.record.properties).sort()).toEqual(["action", "createdAt", "reference", "updatedAt"]);
    const prefs = lexicon("preferences.json").defs.main.record.properties;
    expect(prefs.showSports.default).toBe(true);
    expect(prefs.hideSportsScores.default).toBe(false);
  });
  test("reviewed matchup abbreviations remain optional across event contracts", () => {
    const event = lexicon("discovery/defs.json").defs.sportsEvent;
    const api = readFileSync(join(root, "packages/spec/openapi.yaml"), "utf8");
    for (const field of ["homeAbbreviation", "awayAbbreviation"]) {
      expect(event.properties[field]).toEqual({ type: "string", maxLength: 16 });
      expect(event.required).not.toContain(field);
      expect(api).toContain(`${field}: { type: string, maxLength: 16 }`);
    }
  });
  test("every Sports query has AppView and Gateway Bruno coverage", () => {
    for (const method of ["getSports", "getSportsCatalog", "searchSportsEntities", "getSportsEvents"]) {
      for (const service of ["appview", "gateway"]) {
        const source = readFileSync(join(root, "services", service, "bruno/XRPC", `app.thesocialwire.discovery.${method}.bru`), "utf8");
        expect(source).toContain(`/xrpc/app.thesocialwire.discovery.${method}`);
      }
    }
  });
});
