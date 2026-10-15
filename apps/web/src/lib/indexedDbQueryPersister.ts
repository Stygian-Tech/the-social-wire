"use client";

import type {
  PersistedClient,
  Persister,
} from "@tanstack/react-query-persist-client";

type IndexedDbQueryPersisterOptions = {
  dbName: string;
  storeName: string;
  key: string;
  throttleTime?: number;
  prepareClient?: (client: PersistedClient) => PersistedClient;
};

function canUseIndexedDb(): boolean {
  return typeof window !== "undefined" && "indexedDB" in window;
}

function openDatabase(dbName: string, storeName: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = window.indexedDB.open(dbName, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(storeName)) {
        db.createObjectStore(storeName);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function withStore<T>(
  dbName: string,
  storeName: string,
  mode: IDBTransactionMode,
  operation: (store: IDBObjectStore) => IDBRequest<T>
): Promise<T> {
  const db = await openDatabase(dbName, storeName);
  return new Promise((resolve, reject) => {
    const transaction = db.transaction(storeName, mode);
    const request = operation(transaction.objectStore(storeName));
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
    transaction.oncomplete = () => db.close();
    transaction.onabort = () => {
      db.close();
      reject(transaction.error);
    };
  });
}

export function createIndexedDbQueryPersister({
  dbName,
  storeName,
  key,
  throttleTime = 2_000,
  prepareClient = client => client,
}: IndexedDbQueryPersisterOptions): Persister {
  let pendingClient: PersistedClient | null = null;
  let pendingTimer: number | null = null;

  const writePendingClient = () => {
    if (!canUseIndexedDb() || !pendingClient) return;
    const client = pendingClient;
    pendingClient = null;
    void withStore(dbName, storeName, "readwrite", (store) =>
      store.put(client, key)
    ).catch(() => {
      /* IndexedDB can be unavailable in private mode; persistence is best effort. */
    });
  };

  return {
    persistClient: async (client) => {
      if (!canUseIndexedDb()) return;
      pendingClient = prepareClient(client);
      if (pendingTimer != null) return;
      pendingTimer = window.setTimeout(() => {
        pendingTimer = null;
        writePendingClient();
      }, throttleTime);
    },
    restoreClient: async () => {
      if (!canUseIndexedDb()) return undefined;
      try {
        return await withStore<PersistedClient | undefined>(
          dbName,
          storeName,
          "readonly",
          (store) => store.get(key)
        );
      } catch {
        return undefined;
      }
    },
    removeClient: async () => {
      pendingClient = null;
      if (pendingTimer != null) {
        window.clearTimeout(pendingTimer);
        pendingTimer = null;
      }
      if (!canUseIndexedDb()) return;
      try {
        await withStore(dbName, storeName, "readwrite", (store) =>
          store.delete(key)
        );
      } catch {
        /* best effort */
      }
    },
  };
}
