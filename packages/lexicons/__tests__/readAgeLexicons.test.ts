import { describe, expect, it } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";

const nsid = (name: string) => `app.thesocialwire.appview.${name}`;
const documents = ["markAllRead", "getReadAgeOptions", "markReadBefore"].map((name) =>
  JSON.parse(readFileSync(join(import.meta.dir, `../app/thesocialwire/appview/${name}.json`), "utf8"))
);
const lexicons = new Lexicons(documents);
const before = "2026-09-02T05:00:00Z";

describe("calendar-day read Lexicons", () => {
  it("requires a scope and explicit local time zone for age options", () => {
    expect(() => lexicons.assertValidXrpcParams(nsid("getReadAgeOptions"), {
      kind: "subscribed", timeZone: "America/Chicago",
    })).not.toThrow();
    for (const params of [{ kind: "subscribed" }, { timeZone: "America/Chicago" }, { kind: "subscribed", timeZone: "" }]) {
      expect(() => lexicons.assertValidXrpcParams(nsid("getReadAgeOptions"), params)).toThrow();
    }
  });

  it("accepts empty options and rejects missing, nonpositive, or malformed age fields", () => {
    expect(() => lexicons.assertValidXrpcOutput(nsid("getReadAgeOptions"), {
      referenceDay: before, options: [],
    })).not.toThrow();
    expect(() => lexicons.assertValidXrpcOutput(nsid("getReadAgeOptions"), {
      referenceDay: before, options: [{ days: 1, before, count: 3 }, { days: 4, before: "2026-08-30T05:00:00Z", count: 1 }],
    })).not.toThrow();
    for (const option of [
      { days: 0, before, count: 1 },
      { days: 1, before, count: 0 },
      { days: 1, before: "yesterday", count: 1 },
      { days: 1, before },
    ]) {
      expect(() => lexicons.assertValidXrpcOutput(nsid("getReadAgeOptions"), {
        referenceDay: before, options: [option],
      })).toThrow();
    }
  });

  it("requires the exclusive cutoff on a distinct mutation without changing markAllRead", () => {
    const scope = { kind: "publication", publicationId: "at://did:plc:example/site.standard.publication/news" };
    expect(() => lexicons.assertValidXrpcInput(nsid("markReadBefore"), { scope, before })).not.toThrow();
    expect(() => lexicons.assertValidXrpcInput(nsid("markReadBefore"), { scope })).toThrow();
    expect(() => lexicons.assertValidXrpcInput(nsid("markReadBefore"), { scope, before: "yesterday" })).toThrow();
    expect(documents[0].defs.main.input.schema.required).toEqual(["scope"]);
    expect(documents[0].defs.main.input.schema.properties.before).toBeUndefined();
  });

  it("requires concrete marked IDs and a timestamp for client read-state reconciliation", () => {
    const result = { marked: 1, entryIds: ["at://did:plc:example/site.standard.document/story"], readAt: before, unreadCounts: { news: 3 } };
    expect(() => lexicons.assertValidXrpcOutput(nsid("markReadBefore"), result)).not.toThrow();
    expect(() => lexicons.assertValidXrpcOutput(nsid("markReadBefore"), { ...result, unreadCounts: {} })).not.toThrow();
    for (const field of ["marked", "entryIds", "readAt", "unreadCounts"]) {
      const missing = { ...result } as Record<string, unknown>;
      delete missing[field];
      expect(() => lexicons.assertValidXrpcOutput(nsid("markReadBefore"), missing)).toThrow();
    }
    expect(() => lexicons.assertValidXrpcOutput(nsid("markReadBefore"), { ...result, marked: -1 })).toThrow();
  });
});
