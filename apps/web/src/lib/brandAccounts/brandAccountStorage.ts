const REGISTRY_PREFIX = "the-social-wire.brand-accounts.v1:";
const LINK_KEY = "the-social-wire.brand-link.v1";
export const BRAND_LINK_STATE_PREFIX = "the-social-wire.brand-link:";
export const BRAND_ACCOUNTS_PATH = "/brand-accounts";
const LINK_TTL = 15 * 60 * 1000;
const listeners = new Set<() => void>();
export interface BrandLinkIntent { ownerDid: string; nonce: string; expiresAt: number; clientId: string }
const validDid = (value: unknown): value is string => typeof value === "string" && /^did:[a-z]+:[^\s/?#]+$/.test(value);
function readRegistry(ownerDid: string): string[] {
  if (!validDid(ownerDid)) return [];
  const value: unknown = JSON.parse(window.localStorage.getItem(REGISTRY_PREFIX + ownerDid) ?? "[]");
  if (!Array.isArray(value) || value.some(did => !validDid(did) || did === ownerDid)) throw new Error("Your Linked Account Registry Is Invalid.");
  return [...new Set(value)];
}
export function listBrandAccounts(ownerDid: string): string[] {
  if (typeof window === "undefined") return [];
  try { return readRegistry(ownerDid); } catch { return []; }
}
/** One SDK session exists per DID, so another personal owner cannot share it. */
export function assertBrandAccountAvailable(ownerDid: string, brandDid: string): void {
  if (brandDid === ownerDid || !validDid(ownerDid) || !validDid(brandDid)) throw new Error("Link A Different Account From Your Personal Account.");
  readRegistry(ownerDid);
  for (let index = 0; index < window.localStorage.length; index++) {
    const key = window.localStorage.key(index);
    if (key?.startsWith(REGISTRY_PREFIX) && key !== REGISTRY_PREFIX + ownerDid && readRegistry(key.slice(REGISTRY_PREFIX.length)).includes(brandDid)) throw new Error("This Brand Is Linked To Another Personal Account In This Browser. Unlink It There First.");
  }
}
export function notifyBrandAccountsChanged(): void { listeners.forEach(listener => listener()); }
export function onBrandAccountsChanged(listener: () => void): () => void {
  listeners.add(listener);
  const storage = (event: StorageEvent) => { if (event.key?.startsWith(REGISTRY_PREFIX)) listener(); };
  window.addEventListener("storage", storage);
  return () => { listeners.delete(listener); window.removeEventListener("storage", storage); };
}
export function addBrandAccount(ownerDid: string, brandDid: string): void {
  assertBrandAccountAvailable(ownerDid, brandDid);
  window.localStorage.setItem(REGISTRY_PREFIX + ownerDid, JSON.stringify([...new Set([...readRegistry(ownerDid), brandDid])])); notifyBrandAccountsChanged();
}
export function removeBrandAccount(ownerDid: string, brandDid: string): void {
  window.localStorage.setItem(REGISTRY_PREFIX + ownerDid, JSON.stringify(readRegistry(ownerDid).filter(did => did !== brandDid))); notifyBrandAccountsChanged();
}
export function createBrandLinkIntent(ownerDid: string, clientId: string): BrandLinkIntent {
  if (!validDid(ownerDid)) throw new Error("Sign In To Your Personal Account First.");
  const existing = readBrandLinkIntent();
  if (existing && existing.expiresAt > Date.now()) throw new Error("Finish Or Cancel Your Pending Account Link First.");
  const intent = { ownerDid, clientId, nonce: crypto.randomUUID(), expiresAt: Date.now() + LINK_TTL };
  window.sessionStorage.setItem(LINK_KEY, JSON.stringify(intent)); return intent;
}
export function readBrandLinkIntent(): BrandLinkIntent | null {
  const value = window.sessionStorage.getItem(LINK_KEY); if (!value) return null;
  let intent: Partial<BrandLinkIntent>;
  try { intent = JSON.parse(value); } catch { throw new Error("Your Account Link Intent Is Invalid."); }
  if (!intent || !validDid(intent.ownerDid) || typeof intent.nonce !== "string" || !/^[\w-]{20,80}$/.test(intent.nonce) || !Number.isFinite(intent.expiresAt) || typeof intent.clientId !== "string" || !intent.clientId) throw new Error("Your Account Link Intent Is Invalid.");
  return intent as BrandLinkIntent;
}
export function cancelBrandLinkIntent(): void { window.sessionStorage.removeItem(LINK_KEY); }
export function validateBrandLinkIntent(appState: string, primaryDid: string | null): BrandLinkIntent {
  const intent = readBrandLinkIntent();
  if (!intent || appState !== BRAND_LINK_STATE_PREFIX + intent.nonce || intent.expiresAt <= Date.now() || intent.ownerDid !== primaryDid) throw new Error("Your Account Link Expired Or Your Personal Account Changed.");
  return intent;
}
/** App state is returned only after the SDK validates OAuth state, issuer and PKCE. */
export function completeBrandLinkIntent(appState: string | null, brandDid: string, primaryDid: string | null): boolean {
  if (!appState?.startsWith(BRAND_LINK_STATE_PREFIX)) return false;
  const intent = validateBrandLinkIntent(appState, primaryDid);
  if (brandDid === intent.ownerDid) { cancelBrandLinkIntent(); throw new Error("Link A Different Account From Your Personal Account."); }
  addBrandAccount(intent.ownerDid, brandDid); cancelBrandLinkIntent(); return true;
}
