import { CHUNK_COLLECTION, MANIFEST_COLLECTION, ReadStateError, recordCID,
  type Chunk, type Intent, type Manifest, type OutboxState, type OutboxStore,
  type ReadStateRepository, type RepositoryRecord } from "../src";
export const viewer = "did:plc:alice";
export const at = "2026-09-08T10:00:00Z";
export function intent(actionId: string, state: "read" | "unread" = "read", uris = ["at://article/a"]): Intent {
  return { actionId, state, actedAt: at, selection: "exact", subjectUris: uris };
}
export class Repository implements ReadStateRepository {
  readonly viewerDid = viewer;
  records = new Map<string, RepositoryRecord>();
  writes: string[] = [];
  beforePut?: (collection: string) => Promise<void>;
  failAfterManifest = false;
  async getRecord(collection: string, rkey: string, cid?: string): Promise<RepositoryRecord | null> {
    const record = this.records.get(`${collection}/${rkey}`);
    return record && (!cid || record.cid === cid) ? structuredClone(record) : null;
  }
  async putRecord(collection: string, rkey: string, value: Chunk | Manifest, swapRecord: string | null) {
    await this.beforePut?.(collection);
    const key = `${collection}/${rkey}`;
    if ((this.records.get(key)?.cid ?? null) !== swapRecord) throw new ReadStateError("conflict");
    const record = { uri: `at://${viewer}/${key}`, cid: await recordCID(value), value: structuredClone(value) };
    this.records.set(key, record); this.writes.push(collection);
    if (this.failAfterManifest && collection === MANIFEST_COLLECTION) { this.failAfterManifest = false; throw new Error("Lost response"); }
    return { uri: record.uri, cid: record.cid };
  }
  manifest() { return this.records.get(`${MANIFEST_COLLECTION}/self`)!; }
  chunks() { return [...this.records.values()].filter(record => record.uri.includes(CHUNK_COLLECTION)); }
}
export class Store implements OutboxStore {
  states = new Map<string, OutboxState>();
  async read(viewerDid: string): Promise<OutboxState> { return structuredClone(this.states.get(viewerDid) ?? { viewerDid, entries: [] }); }
  async update(viewerDid: string, update: (state: OutboxState) => OutboxState): Promise<OutboxState> {
    const state = update(structuredClone(this.states.get(viewerDid) ?? { viewerDid, entries: [] })); this.states.set(viewerDid, structuredClone(state)); return state;
  }
}
export function lock() {
  let tail: Promise<unknown> = Promise.resolve();
  return <T>(_key: string, operation: () => Promise<T>): Promise<T> => {
    const result = tail.then(operation); tail = result.catch(() => {}); return result;
  };
}
