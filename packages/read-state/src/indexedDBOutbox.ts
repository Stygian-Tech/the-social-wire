import { ReadStateError } from "./types";
import type { OutboxState, OutboxStore } from "./outbox";

export class IndexedDBReadStateOutbox implements OutboxStore {
  private database?: Promise<IDBDatabase>;
  constructor(private readonly factory: IDBFactory = indexedDB) {}
  private open(): Promise<IDBDatabase> {
    return this.database ??= new Promise((resolve, reject) => {
      let blocked = false;
      const request = this.factory.open("the-social-wire.pds-read-state.v1", 2);
      request.onupgradeneeded = () => {
        if (!request.result.objectStoreNames.contains("viewers")) request.result.createObjectStore("viewers", { keyPath: "viewerDid" });
      };
      request.onsuccess = () => {
        if (blocked) { request.result.close(); this.database = undefined; return; }
        request.result.onversionchange = () => { request.result.close(); this.database = undefined; };
        resolve(request.result);
      };
      request.onerror = () => { this.database = undefined; reject(new ReadStateError("outbox_unavailable")); };
      request.onblocked = () => {
        blocked = true; this.database = undefined;
        reject(new ReadStateError("outbox_unavailable", "Close other Social Wire tabs, then retry. Your pending read changes are preserved."));
      };
    });
  }
  async read(viewer: string): Promise<OutboxState> {
    return this.transaction(viewer, "readonly", state => state);
  }
  async update(viewer: string, update: (state: OutboxState) => OutboxState): Promise<OutboxState> {
    return this.transaction(viewer, "readwrite", update);
  }
  private async transaction(viewer: string, mode: IDBTransactionMode,
    update: (state: OutboxState) => OutboxState): Promise<OutboxState> {
    const database = await this.open();
    return new Promise((resolve, reject) => {
      const transaction = database.transaction("viewers", mode);
      const store = transaction.objectStore("viewers"); const request = store.get(viewer);
      let result: OutboxState;
      transaction.oncomplete = () => resolve(result);
      transaction.onabort = transaction.onerror = () => reject(new ReadStateError("outbox_unavailable"));
      request.onsuccess = () => {
        try {
          result = update(request.result ?? { viewerDid: viewer, entries: [] });
          if (result.viewerDid !== viewer) throw new ReadStateError("invalid_record");
          if (mode === "readwrite") store.put(result);
        } catch (error) { transaction.abort(); reject(error); }
      };
    });
  }
}

/** Cross-tab lock: fail closed if unavailable rather than racing destructive outbox updates. */
export async function browserReadStateLock<T>(viewer: string, operation: () => Promise<T>): Promise<T> {
  if (!navigator.locks) throw new ReadStateError("outbox_unavailable", "This browser cannot safely synchronize read state.");
  return navigator.locks.request(`the-social-wire.read-state:${viewer}`, operation);
}
