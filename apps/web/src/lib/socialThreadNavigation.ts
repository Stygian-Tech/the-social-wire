import { isSocialPostUri, safeSocialPostReturnPath, socialPostPageHref } from "./socialPostNavigation";

export interface SocialThreadReturnPoint {
  uri: string;
  returnTo: string;
  parentToken?: string;
  focused: boolean;
  scrollTop: number;
  anchorUri: string;
  anchorOffset: number;
}

const memory = new Map<string, Map<string, SocialThreadReturnPoint>>();
const pending = new Map<string, SocialThreadReturnPoint>();
const storageKey = (did: string) => `the-social-wire.thread-return.v1:${did}`;
const pendingKey = (did: string, uri: string, parentToken?: string) => JSON.stringify([did, uri, parentToken ?? ""]);

function validPoint(value: unknown): value is SocialThreadReturnPoint {
  if (!value || typeof value !== "object") return false;
  const point = value as SocialThreadReturnPoint;
  return isSocialPostUri(point.uri) && isSocialPostUri(point.anchorUri) && typeof point.returnTo === "string" && safeSocialPostReturnPath(point.returnTo) === point.returnTo && typeof point.focused === "boolean" && Number.isFinite(point.scrollTop) && point.scrollTop >= 0 && Number.isFinite(point.anchorOffset) && (point.parentToken === undefined || /^[a-zA-Z0-9-]{1,80}$/.test(point.parentToken));
}

function points(did: string): Map<string, SocialThreadReturnPoint> {
  const existing = memory.get(did);
  if (existing) return existing;
  const loaded = new Map<string, SocialThreadReturnPoint>();
  try {
    const parsed: unknown = JSON.parse(sessionStorage.getItem(storageKey(did)) ?? "[]");
    if (Array.isArray(parsed)) for (const entry of parsed.slice(-20)) {
      if (Array.isArray(entry) && typeof entry[0] === "string" && /^[a-zA-Z0-9-]{1,80}$/.test(entry[0]) && validPoint(entry[1])) loaded.set(entry[0], entry[1]);
    }
  } catch { /* In-memory return still works when browser storage is blocked. */ }
  memory.set(did, loaded);
  return loaded;
}

export function saveSocialThreadReturnPoint(did: string, point: SocialThreadReturnPoint): string {
  if (!validPoint(point)) throw new Error("This thread return point is invalid.");
  const token = crypto.randomUUID();
  const entries = points(did);
  entries.set(token, point);
  while (entries.size > 20) entries.delete(entries.keys().next().value!);
  try { sessionStorage.setItem(storageKey(did), JSON.stringify([...entries])); } catch { /* Use memory. */ }
  pending.set(pendingKey(did, point.uri, point.parentToken), point);
  while (pending.size > 20) pending.delete(pending.keys().next().value!);
  return token;
}

export function readSocialThreadReturnPoint(did: string, token: string | null | undefined): SocialThreadReturnPoint | undefined {
  return token && /^[a-zA-Z0-9-]{1,80}$/.test(token) ? points(did).get(token) : undefined;
}

export function consumePendingSocialThreadReturn(did: string, uri: string, parentToken?: string): SocialThreadReturnPoint | undefined {
  const key = pendingKey(did, uri, parentToken);
  const point = pending.get(key);
  pending.delete(key);
  return point;
}

/** Tokens keep nested navigation URLs bounded instead of recursively encoding return routes. */
export function socialFocusedThreadHref(uri: string, returnTo: string, token?: string, restoreToken?: string, focused = true): string {
  const params = new URLSearchParams(socialPostPageHref(uri, returnTo).split("?")[1]);
  if (focused) params.set("focusThread", "1");
  if (token && /^[a-zA-Z0-9-]{1,80}$/.test(token)) params.set("threadReturn", token);
  if (restoreToken && /^[a-zA-Z0-9-]{1,80}$/.test(restoreToken)) params.set("threadRestore", restoreToken);
  return `/social/post?${params}`;
}
