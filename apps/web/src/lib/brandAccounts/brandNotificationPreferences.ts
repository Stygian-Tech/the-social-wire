const PREFIX = "the-social-wire.brand-notifications.v1:";

/** The preference is local to the personal account and never stores credentials. */
export function includeBrandNotifications(ownerDid: string): boolean {
  if (typeof window === "undefined") return true;
  try { return window.localStorage.getItem(PREFIX + ownerDid) !== "false"; }
  catch { return true; }
}

export function setIncludeBrandNotifications(ownerDid: string, included: boolean): void {
  try { window.localStorage.setItem(PREFIX + ownerDid, String(included)); }
  catch { /* Keep the selection usable when browser storage is unavailable. */ }
}
