/**
 * Client-only persisted read/unread for article entry AT-URIs.
 *
 * When the user is in the Hidden Publications folder, the UI does not show
 * read indicators and does not call into this module for updates (see ReadRouteContext).
 * Stored keys still exist on disk if the user previously marked entries read elsewhere.
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

export function loadReadState(storage: Pick<Storage, "getItem">): EntryReadStateV1 {
  try {
    return parseReadStateJson(storage.getItem(READ_STATE_STORAGE_KEY));
  } catch {
    return {};
  }
}

export function saveReadState(
  storage: Pick<Storage, "setItem">,
  state: EntryReadStateV1
): void {
  try {
    storage.setItem(READ_STATE_STORAGE_KEY, JSON.stringify(state));
  } catch {
    // quota / private mode
  }
}

/** When two clients report read times for the same entry, keep the earlier (first read). */
export function pickEarlierReadAt(a: string, b: string): string {
  const da = Date.parse(a);
  const db = Date.parse(b);
  const aOk = !Number.isNaN(da);
  const bOk = !Number.isNaN(db);
  if (aOk && bOk) return da <= db ? a : b;
  if (aOk) return a;
  if (bOk) return b;
  return a;
}

/**
 * Merges remote PDS read state into local map. Per entry, the earlier `readAt` wins.
 */
export function mergeReadStateMaps(
  local: EntryReadStateV1,
  remote: EntryReadStateV1
): EntryReadStateV1 {
  const out: EntryReadStateV1 = { ...local };
  for (const [id, remoteTs] of Object.entries(remote)) {
    const localTs = out[id];
    if (!localTs) {
      out[id] = remoteTs;
    } else {
      out[id] = pickEarlierReadAt(localTs, remoteTs);
    }
  }
  return out;
}
