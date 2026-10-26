import { expect, test } from "bun:test";
import { jsonStringToLex, Lexicons } from "@atproto/lexicon";
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
test("actual session closure is optional and distinct from the scheduled end", () => {
  expect(() => lexicons.assertValidRecord(schema.id, { ...event, endsAt: "2026-10-11T13:00:00Z", endedAt: "2026-10-11T12:30:00Z" })).not.toThrow();
  expect(() => lexicons.assertValidRecord(schema.id, { ...event, endedAt: "yesterday" })).toThrow();
  expect(schema.defs.main.record.properties.endedAt).toMatchObject({ type: "string", format: "datetime" });
});
test("live update media schema validates blobs and bounds attachments", () => {
  const image = { alt: "Event photo", blob: { $type: "blob", ref: { $link: "bafkreihdwdcefgh4dqkjv67uzcmw7ojee6xedzdetojuzjevtenxquvyku" }, mimeType: "image/png", size: 100 } };
  const record = (media: unknown) => jsonStringToLex(JSON.stringify({ ...event, entries: [{ ...event.entries[0], attachmentsFingerprint: "a".repeat(64), media }] }));
  expect(() => lexicons.assertValidRecord(schema.id, record({ images: [image] }))).not.toThrow();
  expect(() => lexicons.assertValidRecord(schema.id, record({ gif: { url: "https://example.com/live.gif", alt: "Event animation" } }))).not.toThrow();
  expect(() => lexicons.assertValidRecord(schema.id, record({ images: Array(5).fill(image) }))).toThrow();
  expect(() => lexicons.assertValidRecord(schema.id, record({ images: [{ alt: "Missing blob" }] }))).toThrow();
  expect(schema.defs.image.properties.blob.maxSize).toBe(2_000_000);
  expect(schema.defs.video.properties.blob.accept).toEqual(["video/mp4"]);
});
