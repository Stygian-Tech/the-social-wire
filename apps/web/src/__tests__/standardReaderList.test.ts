import { describe, expect, test } from "bun:test";
import type { OAuthSession } from "@atproto/oauth-client-browser";
import { PDSClient } from "@/lib/pdsClient";
import { STANDARD_READER_LIST_COLLECTION, STANDARD_READER_LIST_SAVE_COLLECTION, isStandardReaderListRecord, isStandardReaderListSaveRecord, parseStandardReaderListUri, standardReaderListSaveRkey, standardReaderListRecord, standardReaderListShareUrl } from "@/lib/standardReaderList";

const viewer = "did:plc:viewer";
const list = "at://did:plc:creator/app.standard-reader.list/3moc2s6xjao2q";
const createdAt = "2026-10-02T12:00:00.000Z";
const record = { $type: STANDARD_READER_LIST_COLLECTION, name: "Reading", publications: ["at://did:plc:creator/site.standard.publication/3moc2s6xjao2q"], users: ["did:plc:author"], createdAt };
const save = (rkey: string, target = list) => ({ uri: `at://${viewer}/${STANDARD_READER_LIST_SAVE_COLLECTION}/${rkey}`, cid: `cid-${rkey}`, value: { $type: STANDARD_READER_LIST_SAVE_COLLECTION, list: target, createdAt } });
function client(pages: { records: ReturnType<typeof save>[]; cursor?: string }[], options: { afterDelete?: () => void; listReadError?: Error } = {}) {
  const oauth = { did: viewer } as unknown as OAuthSession;
  const calls: { read: unknown[]; write: Record<string, unknown>[]; remove: Record<string, unknown>[]; create: Record<string, unknown>[] } = { read: [], write: [], remove: [], create: [] };
  let page = 0;
  const value = Object.create(PDSClient.prototype) as PDSClient;
  Object.assign(value, { did: viewer, oauthSession: oauth, agent: { api: { com: { atproto: { repo: {
    listRecords: async (input: unknown) => { calls.read.push(input); if (options.listReadError) throw options.listReadError; return { data: pages[page++]! }; },
    putRecord: async (input: Record<string, unknown>) => { calls.write.push(input); return { data: { uri: `at://${viewer}/${STANDARD_READER_LIST_SAVE_COLLECTION}/${input.rkey}`, cid: "new-cid" } }; },
    deleteRecord: async (input: Record<string, unknown>) => { calls.remove.push(input); options.afterDelete?.(); },
    createRecord: async (input: Record<string, unknown>) => { calls.create.push(input); return { data: { uri: `at://${viewer}/${STANDARD_READER_LIST_COLLECTION}/3moc2s6xjao2q`, cid: "created-cid" } }; },
  } } } } } });
  return { value, calls, oauth };
}

describe("Standard Reader list contracts", () => {
  test("accepts canonical references and rejects wrong collections, handles and URL guesses", () => {
    expect(parseStandardReaderListUri(` ${list} `)).toBe(list);
    for (const bad of [list.replace("app.standard-reader.list", "app.standard-reader.listSave"), list + "/extra", list + "?x=1", "https://standard-reader.app/lists/guessed", "at://creator.test/app.standard-reader.list/key"])
      expect(parseStandardReaderListUri(bad)).toBeNull();
  });
  test("validates publication/author members and limits without sorting their order", () => {
    expect(isStandardReaderListRecord(record)).toBe(true);
    expect(isStandardReaderListRecord({ ...record, publications: [], users: ["did:plc:author"] })).toBe(true);
    expect(isStandardReaderListRecord({ ...record, publications: [list] })).toBe(false);
    expect(isStandardReaderListRecord({ ...record, publications: Array(501).fill(record.publications[0]) })).toBe(false);
    expect(isStandardReaderListRecord({ ...record, users: ["author.test"] })).toBe(false);
    expect(isStandardReaderListRecord({ ...record, createdAt: "today" })).toBe(false);
  });
  test("enforces grapheme and UTF8 byte limits", () => {
    expect(isStandardReaderListRecord({ ...record, name: "a".repeat(65) })).toBe(false);
    expect(isStandardReaderListRecord({ ...record, name: "👨‍👩‍👧‍👦".repeat(26) })).toBe(false);
    expect(isStandardReaderListRecord({ ...record, name: "e\u0301".repeat(64) })).toBe(true);
    expect(isStandardReaderListRecord({ ...record, description: "a".repeat(301) })).toBe(false);
  });
  test("validates save references and timestamps", () => {
    expect(isStandardReaderListSaveRecord(save("first").value)).toBe(true);
    expect(isStandardReaderListSaveRecord({ ...save("first").value, list: record.publications[0] })).toBe(false);
    expect(isStandardReaderListSaveRecord({ ...save("first").value, createdAt: "invalid" })).toBe(false);
  });
  test("keys are stable across whitespace and distinguish list identities", async () => {
    const rkey = await standardReaderListSaveRkey(list);
    expect(rkey).toHaveLength(64);
    expect(await standardReaderListSaveRkey(` ${list} `)).toBe(rkey);
    expect(await standardReaderListSaveRkey(list.replace("creator", "other"))).not.toBe(rkey);
  });
});

describe("Standard Reader direct PDS writes", () => {
  test("writes only the viewer's save record with a deterministic key", async () => {
    const { value, calls } = client([{ records: [] }]);
    await value.saveStandardReaderList(list);
    expect(calls.write).toEqual([{ repo: viewer, collection: STANDARD_READER_LIST_SAVE_COLLECTION, rkey: await standardReaderListSaveRkey(list), record: { $type: STANDARD_READER_LIST_SAVE_COLLECTION, list, createdAt: expect.any(String) } }]);
  });
  test("finds an arbitrary existing save key across pages without changing its timestamp", async () => {
    const existing = save("old-client-key");
    const { value, calls } = client([{ records: [], cursor: "next" }, { records: [existing] }]);
    expect(await value.saveStandardReaderList(list)).toEqual({ uri: existing.uri, cid: existing.cid });
    expect(calls.read).toHaveLength(2);
    expect(calls.write).toHaveLength(0);
  });
  test("removes every duplicate key and preserves unrelated or foreign records", async () => {
    const foreign = { ...save("foreign"), uri: `at://did:plc:other/${STANDARD_READER_LIST_SAVE_COLLECTION}/foreign` };
    const { value, calls } = client([{ records: [save("a"), save("unrelated", list.replace("creator", "other"))], cursor: "next" }, { records: [save("b"), save("a"), foreign] }]);
    await value.removeStandardReaderList(list);
    expect(calls.remove.map(call => call.rkey)).toEqual(["a", "b"]);
    expect(calls.write).toHaveLength(0);
  });
  test("invalid target references never read or mutate records", async () => {
    const { value, calls } = client([]);
    await expect(value.saveStandardReaderList(record.publications[0]!)).rejects.toThrow("AT URI");
    await expect(value.removeStandardReaderList(record.publications[0]!)).rejects.toThrow("AT URI");
    expect(calls.read).toHaveLength(0);
    expect(calls.remove).toHaveLength(0);
  });
  test("rejects stale account state before reads or writes", async () => {
    const { value, calls, oauth } = client([]);
    Object.assign(oauth, { did: "did:plc:other" });
    await expect(value.saveStandardReaderList(list)).rejects.toThrow("account changed");
    await expect(value.removeStandardReaderList(list)).rejects.toThrow("account changed");
    expect(calls.read).toHaveLength(0);
  });
  test("fails rather than looping or writing on repeated continuation", async () => {
    const { value, calls } = client([{ records: [], cursor: "same" }, { records: [], cursor: "same" }]);
    await expect(value.saveStandardReaderList(list)).rejects.toThrow("completely");
    expect(calls.write).toHaveLength(0);
  });
});


describe("Standard Reader owned lists", () => {
  test("creates a validated public list using PDS-generated TID without saving it", async () => {
    const { value, calls } = client([]);
    const input = { name: " Reading ", description: " A shared list ", publications: record.publications, users: record.users };
    const created = await value.createStandardReaderList(input);
    expect(created.uri).toBe(`at://${viewer}/${STANDARD_READER_LIST_COLLECTION}/3moc2s6xjao2q`);
    expect(calls.create[0]).toMatchObject({ repo: viewer, collection: STANDARD_READER_LIST_COLLECTION, record: { name: "Reading", description: "A shared list", publications: record.publications, users: record.users } });
    expect(calls.create[0]).not.toHaveProperty("rkey");
    expect(calls.write).toHaveLength(0);
  });
  test("rejects blank names and invalid/oversized members before creation", async () => {
    const { value, calls } = client([]);
    for (const input of [{ name: " ", publications: [] }, { name: "Reading", publications: [list] }, { name: "Reading", publications: [` ${record.publications[0]} `] }, { name: "Reading", publications: [], users: Array(501).fill("did:plc:author") }]) {
      await expect(value.createStandardReaderList(input)).rejects.toThrow("valid publication");
    }
    expect(calls.create).toHaveLength(0);
  });
  test("deletes the original owned record then only the viewer's saved references", async () => {
    const owned = list.replace("creator", "viewer");
    const { value, calls } = client([{ records: [save("also-saved", owned), save("other-saved", list)] }]);
    await value.deleteOwnedStandardReaderList(owned);
    expect(calls.remove).toEqual([
      { repo: viewer, collection: STANDARD_READER_LIST_COLLECTION, rkey: "3moc2s6xjao2q" },
      { repo: viewer, collection: STANDARD_READER_LIST_SAVE_COLLECTION, rkey: "also-saved" },
    ]);
  });
  test("never deletes another creator's original or a listSave record as an original", async () => {
    const { value, calls } = client([]);
    await expect(value.deleteOwnedStandardReaderList(list)).rejects.toThrow("Only a list created");
    await expect(value.deleteOwnedStandardReaderList(save("key").uri)).rejects.toThrow("Only a list created");
    expect(calls.remove).toHaveLength(0);
  });
  test("reports committed original deletion truthfully when saved-reference cleanup fails", async () => {
    const { value, calls } = client([]);
    let failure: unknown;
    try { await value.deleteOwnedStandardReaderList(list.replace("creator", "viewer")); } catch (error) { failure = error; }
    expect(failure).toMatchObject({ originalDeleted: true });
    expect((failure as Error).message).toContain("Your list was deleted");
    expect(calls.remove[0]?.collection).toBe(STANDARD_READER_LIST_COLLECTION);
  });
  test("marks original deletion as committed if the account changes before saved-reference cleanup", async () => {
    let afterDelete = () => undefined;
    const { value, calls, oauth } = client([], { afterDelete: () => afterDelete() });
    afterDelete = () => { Object.assign(oauth, { did: "did:plc:other" }); };
    let failure: unknown;
    try { await value.deleteOwnedStandardReaderList(list.replace("creator", "viewer")); } catch (error) { failure = error; }
    expect(failure).toMatchObject({ originalDeleted: true });
    expect(calls.remove).toHaveLength(1);
    expect(calls.read).toHaveLength(0);
  });
  test("keeps committed deletion and actionable OAuth recovery for a cleanup scope error", async () => {
    const cause = Object.assign(new Error("insufficient scope"), { status: 403 });
    const { value } = client([], { listReadError: cause });
    let failure: unknown;
    try { await value.deleteOwnedStandardReaderList(list.replace("creator", "viewer")); } catch (error) { failure = error; }
    expect(failure).toMatchObject({ originalDeleted: true, cause });
    expect((failure as Error).message).toContain("Sign out and sign in again");
  });
  test("ownership writes reject a stale viewer before touching records", async () => {
    const { value, calls, oauth } = client([]);
    Object.assign(oauth, { did: "did:plc:other" });
    await expect(value.createStandardReaderList({ name: "Reading", publications: [] })).rejects.toThrow("account changed");
    await expect(value.deleteOwnedStandardReaderList(list.replace("creator", "viewer"))).rejects.toThrow("account changed");
    expect(calls.create).toHaveLength(0);
    expect(calls.remove).toHaveLength(0);
  });
  test("shares the canonical public official route and rejects wrong record collections", () => {
    expect(standardReaderListShareUrl(list)).toBe("https://standard-reader.app/l/did%3Aplc%3Acreator/3moc2s6xjao2q");
    expect(() => standardReaderListShareUrl(save("key").uri)).toThrow("AT URI");
    expect(standardReaderListRecord({ name: "Reading", publications: [], users: [] }, createdAt)).toEqual({ $type: STANDARD_READER_LIST_COLLECTION, name: "Reading", publications: [], createdAt });
  });
});
