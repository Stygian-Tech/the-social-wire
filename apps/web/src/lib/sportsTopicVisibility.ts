import type { AppEnv } from "@/lib/appEnv";

export const SPORTS_VISIBILITY_MAX_AGE_MS = 24 * 60 * 60 * 1000;
const PREFIX = "the-social-wire.sports-visibility.v1";
type Confirmation = { enabled: boolean; confirmedAt: number };
const memory = new Map<string, Confirmation>();
const listeners = new Set<() => void>();

export function sportsVisibilityStorageKey(environment: AppEnv, origin: string): string {
  return `${PREFIX}:${environment}:${origin}`;
}

export function readSportsVisibility(storage: Pick<Storage, "getItem"> | undefined, environment: AppEnv, origin: string, now = Date.now()): boolean | undefined {
  const key = sportsVisibilityStorageKey(environment, origin);
  let record = memory.get(key);
  try {
    const persisted = JSON.parse(storage?.getItem(key) ?? "null") as Partial<Confirmation> | null;
    if (persisted && typeof persisted.enabled === "boolean" && typeof persisted.confirmedAt === "number" && Number.isFinite(persisted.confirmedAt) && (!record || persisted.confirmedAt > record.confirmedAt)) record = persisted as Confirmation;
  } catch { /* Visibility remains unknown without a valid server confirmation. */ }
  if (!record || record.confirmedAt > now || now - record.confirmedAt >= SPORTS_VISIBILITY_MAX_AGE_MS) return undefined;
  return record.enabled;
}

export function rememberSportsVisibility(storage: Pick<Storage, "setItem"> & Partial<Pick<Storage, "getItem">> | undefined, environment: AppEnv, origin: string, enabled: boolean, confirmedAt: number): void {
  const key = sportsVisibilityStorageKey(environment, origin);
  const now = Date.now();
  let previous = memory.get(key);
  if (previous && previous.confirmedAt > now) previous = undefined;
  try {
    const stored = JSON.parse(storage?.getItem?.(key) ?? "null") as Partial<Confirmation> | null;
    if (stored && typeof stored.enabled === "boolean" && typeof stored.confirmedAt === "number" && Number.isFinite(stored.confirmedAt) && stored.confirmedAt <= now && (!previous || stored.confirmedAt > previous.confirmedAt)) previous = stored as Confirmation;
  } catch { /* Use the in-memory confirmation when storage is unavailable. */ }
  if (previous && previous.confirmedAt > confirmedAt) return;
  const record = { enabled, confirmedAt };
  memory.set(key, record);
  try { storage?.setItem(key, JSON.stringify(record)); } catch { /* Keep the confirmation in memory when browser storage is blocked. */ }
  listeners.forEach(listener => listener());
}

export function browserSportsVisibility(environment: AppEnv): boolean | undefined {
  if (typeof window === "undefined") return undefined;
  let storage: Storage | undefined;
  try { storage = window.localStorage; } catch { /* Restricted browser storage. */ }
  return readSportsVisibility(storage, environment, window.location.origin);
}

export function rememberBrowserSportsVisibility(environment: AppEnv, enabled: boolean, confirmedAt: number): void {
  if (typeof window === "undefined") return;
  let storage: Storage | undefined;
  try { storage = window.localStorage; } catch { /* Restricted browser storage. */ }
  rememberSportsVisibility(storage, environment, window.location.origin, enabled, confirmedAt);
}

export function subscribeSportsVisibility(listener: () => void): () => void {
  listeners.add(listener);
  const onStorage = (event: StorageEvent) => {
    if (event.key === null || event.key.startsWith(PREFIX)) {
      if (event.key === null) memory.clear(); else memory.delete(event.key);
      listener();
    }
  };
  window.addEventListener("storage", onStorage);
  return () => { listeners.delete(listener); window.removeEventListener("storage", onStorage); };
}
