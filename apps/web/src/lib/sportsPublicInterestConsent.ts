const PREFIX = "the-social-wire.sports-public-interest-consent.v1";
const sessionAcknowledgements = new Set<string>();

export function sportsPublicInterestConsentStorageKey(viewerDID: string): string {
  return `${PREFIX}:${viewerDID}`;
}

function sessionKey(viewerDID: string): string {
  return `${window.location.origin}:${sportsPublicInterestConsentStorageKey(viewerDID)}`;
}

export function readSportsPublicInterestConsent(viewerDID?: string): boolean {
  if (!viewerDID || typeof window === "undefined") return false;
  try {
    const record = JSON.parse(window.localStorage.getItem(sportsPublicInterestConsentStorageKey(viewerDID)) ?? "null") as { version?: unknown; acknowledgedAt?: unknown } | null;
    if (record?.version === 1 && typeof record.acknowledgedAt === "number" && Number.isFinite(record.acknowledgedAt)
      && record.acknowledgedAt > 0 && record.acknowledgedAt <= Date.now()) return true;
  } catch { /* Restricted browser storage uses an acknowledgement for this session only. */ }
  return sessionAcknowledgements.has(sessionKey(viewerDID));
}

export function acknowledgeSportsPublicInterests(viewerDID?: string): void {
  if (!viewerDID || typeof window === "undefined") return;
  sessionAcknowledgements.add(sessionKey(viewerDID));
  try {
    window.localStorage.setItem(sportsPublicInterestConsentStorageKey(viewerDID), JSON.stringify({ version: 1, acknowledgedAt: Date.now() }));
  } catch { /* Keep explicit consent for this session when persistence is unavailable. */ }
}
