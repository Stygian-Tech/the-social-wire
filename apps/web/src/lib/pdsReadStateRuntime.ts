import type { OAuthSession } from "@atproto/oauth-client-browser";
import type { PDSReadStateSync } from "./pdsReadStateSync";

// Every signed-in route imports these. The sync engine and its CBOR/outbox dependencies
// load on first use, so builds or viewers without PDS read state never download them.
export const PDS_READ_HISTORY_NOTICE = "Read and unread history is public on your PDS. Pending changes remain on this device until synchronization completes.";
export const pdsReadStateEnabled = () => process.env.NEXT_PUBLIC_PDS_READ_STATE_ENABLED === "true";
export const PDS_READ_STATE_SYNC_EVENT = "socialwire:pds-read-state-sync";

export async function loadPDSReadStateSync(oauth: OAuthSession): Promise<PDSReadStateSync> {
  return (await import("./pdsReadStateSync")).pdsReadStateSync(oauth);
}

/** A migrated account fails closed if status is unavailable: never silently fall back to legacy writes. */
export async function usesPDSReadState(oauth: OAuthSession, force = false): Promise<boolean> {
  if (!pdsReadStateEnabled()) return false;
  return (await import("./pdsReadStateSync")).usesPDSReadState(oauth, force);
}
