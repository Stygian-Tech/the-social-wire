import { describe, expect, it } from "bun:test";

import {
  defaultSidebarExpandedKeys,
  folderExpandKey,
  loadSidebarExpandedKeys,
  migrateLegacyFolderUriExpandKeys,
  migrateStoredSidebarFolderExpandKey,
  saveSidebarExpandedKeys,
  SIDEBAR_EXPANDED_KEYS_STORAGE_KEY,
} from "@/lib/sidebarExpandedKeysStorage";
import {
  SIDEBAR_SEC_FOLDERS,
  SIDEBAR_SEC_PUBLICATIONS,
} from "@/components/AppSidebar/appSidebarConstants";

function mockStorage() {
  const store: Record<string, string> = {};
  return {
    store,
    getItem(key: string) {
      return store[key] ?? null;
    },
    setItem(key: string, value: string) {
      store[key] = value;
    },
  };
}

describe("sidebarExpandedKeysStorage", () => {
  it("defaults to section keys when unset", () => {
    const storage = mockStorage();
    expect(loadSidebarExpandedKeys(storage, "did:plc:test")).toEqual(
      defaultSidebarExpandedKeys()
    );
  });

  it("persists expanded keys per viewer did", () => {
    const storage = mockStorage();
    const did = "did:plc:viewer";
    const keys = new Set([
      SIDEBAR_SEC_FOLDERS,
      SIDEBAR_SEC_PUBLICATIONS,
      folderExpandKey("abc123"),
    ]);
    saveSidebarExpandedKeys(storage, did, keys);

    expect(JSON.parse(storage.store[SIDEBAR_EXPANDED_KEYS_STORAGE_KEY]!)).toEqual({
      [did]: [SIDEBAR_SEC_FOLDERS, SIDEBAR_SEC_PUBLICATIONS, "folder:abc123"],
    });
    expect(loadSidebarExpandedKeys(storage, did)).toEqual(keys);
  });

  it("migrates optimistic folder rkeys after create", () => {
    const storage = mockStorage();
    const did = "did:plc:viewer";
    saveSidebarExpandedKeys(storage, did, [
      SIDEBAR_SEC_FOLDERS,
      folderExpandKey("optimistic-folder-old"),
    ]);

    migrateStoredSidebarFolderExpandKey(
      storage,
      did,
      "optimistic-folder-old",
      "real-folder-rkey"
    );

    expect(loadSidebarExpandedKeys(storage, did)).toEqual(
      new Set([SIDEBAR_SEC_FOLDERS, folderExpandKey("real-folder-rkey")])
    );
  });

  it("migrates legacy folder uri keys to rkey keys", () => {
    const uri = "at://did:plc:viewer/app.thesocialwire.folder/abc123";
    const keys = new Set([SIDEBAR_SEC_FOLDERS, uri]);
    const migrated = migrateLegacyFolderUriExpandKeys(keys, [uri]);
    expect(migrated).toEqual(new Set([SIDEBAR_SEC_FOLDERS, folderExpandKey("abc123")]));
  });
});
