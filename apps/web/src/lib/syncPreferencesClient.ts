import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { PreferencesRecord, RepoRecord } from "@/lib/pdsClient";
import { COLLECTION_PREFERENCES } from "@/lib/pdsClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";

export type SyncPreferencesEnvelope = {
  etag?: string | null;
  cid?: string | null;
  revision?: string | null;
  cachedAt?: string | null;
  record?: PreferencesRecord | null;
};

export function syncPreferencesPath(forceRefresh = false): string {
  return forceRefresh
    ? "/v1/sync/preferences?fresh=1"
    : socialWireXrpc.getPreferences;
}

export async function decodeSyncPreferencesResponse(
  res: Response,
  viewerDid: string,
): Promise<RepoRecord<PreferencesRecord> | null> {
  if (res.status === 304) return null;
  if (!res.ok) throw new Error(`Preference sync failed (${res.status}).`);

  const envelope = (await res.json()) as SyncPreferencesEnvelope;
  const record = envelope.record;
  if (!record) return null;

  const revision =
    envelope.cid?.trim() ||
    envelope.revision?.trim() ||
    envelope.etag?.replace(/^"|"$/g, "").trim() ||
    "";

  return {
    uri: `at://${viewerDid}/${COLLECTION_PREFERENCES}/self`,
    cid: revision,
    value: record,
  };
}

export async function fetchSyncPreferences(
  oauthSession: OAuthSession,
  viewerDid: string,
  ifNoneMatch?: string | null,
  forceRefresh = false,
): Promise<RepoRecord<PreferencesRecord> | null> {
  const path = syncPreferencesPath(forceRefresh);
  const res = await gatewayFetch(oauthSession, path, {
    method: "GET",
    headers: ifNoneMatch ? { "If-None-Match": ifNoneMatch } : undefined,
  });

  return decodeSyncPreferencesResponse(res, viewerDid);
}
