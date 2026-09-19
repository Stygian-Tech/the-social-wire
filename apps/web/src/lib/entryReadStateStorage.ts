/**
 * Client-only persisted read/unread for article entry AT-URIs.
 */

export const READ_STATE_STORAGE_KEY = "the-social-wire.read-state.v1";

/** entryId (AT-URI) → ISO timestamp when marked read */
export type EntryReadStateV1 = Record<string, string>;

export function parseReadStateJson(raw: string | null): EntryReadStateV1 {
  if (raw == null || raw === "") return {};
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return {};
    const out: EntryReadStateV1 = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof v === "string" && v.length > 0) out[k] = v;
    }
    return out;
  } catch {
    return {};
  }
}

export function loadReadState(storage: Pick<Storage, "getItem">, key = READ_STATE_STORAGE_KEY): EntryReadStateV1 {
  try {
    return parseReadStateJson(storage.getItem(key));
  } catch {
    return {};
  }
}

export function saveReadState(
  storage: Pick<Storage, "setItem">,
  state: EntryReadStateV1,
  key = READ_STATE_STORAGE_KEY
): void {
  try {
    storage.setItem(key, JSON.stringify(state));
  } catch {
    // quota / private mode
  }
}

/** Do not import the former shared-device cache into an authenticated viewer. */
export function viewerReadStateStorageKey(viewerDid?: string): string {
  return `the-social-wire.read-state.v2:${viewerDid ?? "anonymous"}`;
}
