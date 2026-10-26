import { expect, test } from "bun:test";
import { Lexicons } from "@atproto/lexicon";
import { readFileSync } from "node:fs";
import { join } from "node:path";
const schema = JSON.parse(readFileSync(join(import.meta.dir, "../app/thesocialwire/liveEvent.json"), "utf8"));
const strongRef = { lexicon: 1, id: "com.atproto.repo.strongRef", defs: { main: { type: "object", required: ["uri", "cid"], properties: { uri: { type: "string", format: "at-uri" }, cid: { type: "string", format: "cid" } } } } };
const lexicons = new Lexicons([schema, strongRef]);
const event = { $type: schema.id, title: "Live", tags: ["news"], destination: "both", publicationUri: "at://did:plc:alice/site.standard.publication/one", createdAt: "2026-10-11T12:00:00Z", updatedAt: "2026-10-11T12:00:00Z", entries: [{ id: "operation", text: "Hello", createdAt: "2026-10-11T12:00:00Z", postRef: { uri: "at://did:plc:alice/app.bsky.feed.post/one", cid: "bafyreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" } }] };
test("live events validate actual update refs and bound public record content", () => {
  expect(() => lexicons.assertValidRecord(schema.id, event)).not.toThrow();
  for (const invalid of [{ destination: "other" }, { tags: Array(21).fill("tag") }, { createdAt: "today" }, { entries: Array(501).fill(event.entries[0]) }, { entries: [{ ...event.entries[0], postRef: { uri: "https://example.com", cid: "bad" } }] }]) expect(() => lexicons.assertValidRecord(schema.id, { ...event, ...invalid })).toThrow();
  expect(schema.defs.main.key).toBe("tid");
});

test("optional timestamp settings preserve legacy validity and constrain format/timezone storage", () => {
  expect(() => lexicons.assertValidRecord(schema.id, { ...event, timestampFormat: "time-24", timeZone: "America/Chicago" })).not.toThrow();
  for (const invalid of [{ timestampFormat: "raw" }, { timeZone: 5 }, { timeZone: "a".repeat(129) }]) expect(() => lexicons.assertValidRecord(schema.id, { ...event, ...invalid })).toThrow();
});
