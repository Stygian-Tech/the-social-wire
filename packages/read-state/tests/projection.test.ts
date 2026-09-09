import { expect, test } from "bun:test";
import { ReadStateProjection, type Operation } from "../src";
import { at, intent } from "./fixture";

test("frozen publication boundaries, UTF-8 ties, explicit unread and later bulk read preserve order", () => {
  const boundary: Operation = { actionId: "bulk", sequence: 1, state: "read", actedAt: at,
    selection: "boundaries", boundaries: [{ scope: { publicationId: "pub", authorDid: "did:plc:a", publicationSiteKeys: ["https://site/a"] }, createdAt: at, entryId: "b" }] };
  const subject = { uri: "b", authorDid: "did:plc:a", publicationSite: "https://site/a", createdAt: at };
  const unread: Operation = { ...intent("individual", "unread", ["b"]), sequence: 2 };
  expect(new ReadStateProjection([boundary], 1).resolve(subject).isRead).toBe(true);
  expect(new ReadStateProjection([boundary, unread], 2).resolve(subject).isRead).toBe(false);
  expect(new ReadStateProjection([boundary, unread, { ...boundary, actionId: "later", sequence: 3 }], 3).resolve(subject).isRead).toBe(true);
  const projection = new ReadStateProjection([boundary], 1);
  expect(projection.resolve({ ...subject, publicationSite: "https://site/added-later" }).isRead).toBe(false);
  expect(projection.resolve({ ...subject, uri: "c" }).isRead).toBe(false);
  expect(projection.resolve({ ...subject, uri: "arrived-later", createdAt: "2026-09-07T10:00:00Z" }).isRead).toBe(true);
});
test("age selections preserve exact set across DST and do not expand to later backfills", () => {
  const operation: Operation = { ...intent("age", "read", ["existing"]), sequence: 1,
    calendar: { cutoff: "2026-03-08T06:00:00Z", timeZone: "America/Chicago", referenceDate: "2026-03-09" } };
  const projection = new ReadStateProjection([operation], 1);
  const subject = { uri: "existing", authorDid: "did:plc:a", createdAt: "2026-03-07T10:00:00Z" };
  expect(projection.resolve(subject).isRead).toBe(true);
  expect(projection.resolve({ ...subject, uri: "late-backfill" }).isRead).toBe(false);
});

test("microsecond boundary comparison does not mark a later timestamp within the same millisecond", () => {
  const operation: Operation = { actionId: "micro", sequence: 1, state: "read", actedAt: at,
    selection: "boundaries", boundaries: [{ scope: { publicationId: "pub", authorDid: "did:plc:a", publicationSiteKeys: [] },
      createdAt: "2026-09-08T10:00:00.123456Z", entryId: "z" }] };
  const projection = new ReadStateProjection([operation], 1);
  expect(projection.resolve({ uri: "a", authorDid: "did:plc:a", createdAt: "2026-09-08T10:00:00.123457Z" }).isRead).toBe(false);
  expect(projection.resolve({ uri: "a", authorDid: "did:plc:a", createdAt: "2026-09-08T05:00:00.123456-05:00" }).isRead).toBe(true);
});


test("operation timestamps reject precision unsupported by the shared native/backend protocol", async () => {
  const { validateIntent } = await import("../src");
  const value = { actionId: "precise", state: "read" as const, selection: "exact" as const, subjectUris: ["article"], actedAt: "2026-09-08T12:00:00.123456789Z" };
  expect(() => validateIntent(value)).not.toThrow();
  expect(() => validateIntent({ ...value, actedAt: "2026-09-08T12:00:00.1234567890Z" })).toThrow("invalid_record");
});
