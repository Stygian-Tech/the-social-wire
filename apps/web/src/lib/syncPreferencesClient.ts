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

export async function fetchSyncPreferences(
  oauthSession: OAuthSession,
  viewerDid: string,
  ifNoneMatch?: string | null
): Promise<RepoRecord<PreferencesRecord> | null> {
  const res = await gatewayFetch(oauthSession, socialWireXrpc.getPreferences, {
    method: "GET",
    headers: ifNoneMatch ? { "If-None-Match": ifNoneMatch } : undefined,
  });

  if (res.status === 304) {
    return null;
  }

  if (!res.ok) {
    return null;
  }

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
