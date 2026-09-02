import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { GatewayMarkAllReadScope } from "@/lib/publicationProjectionClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";

export type ReadAgeOption = {
  days: number;
  before: string;
  count: number;
};

export type ReadAgeOptionsResponse = {
  referenceDay: string;
  options: ReadAgeOption[];
};

export type MarkReadBeforeResponse = {
  marked: number;
  entryIds: string[];
  readAt: string;
  unreadCounts: Record<string, number>;
};

export async function fetchReadAgeOptions(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope,
  timeZone: string
): Promise<ReadAgeOptionsResponse> {
  const params = new URLSearchParams({ kind: scope.kind, timeZone });
  if (scope.kind === "publication") {
    params.set("publicationId", scope.publicationId);
  } else if (scope.kind === "folder") {
    params.set("folderRkey", scope.folderRkey);
  }
  const response = await gatewayFetch(
    oauthSession,
    `${socialWireXrpc.getReadAgeOptions}?${params.toString()}`,
    { method: "GET" }
  );
  if (!response.ok) {
    throw new Error(`Read age options failed (${response.status})`);
  }
  return (await response.json()) as ReadAgeOptionsResponse;
}

export async function markReadBefore(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope,
  before: string
): Promise<MarkReadBeforeResponse> {
  // Keep this separate from markAllRead: old servers ignore unknown cutoff fields.
  const response = await gatewayFetch(oauthSession, socialWireXrpc.markReadBefore, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ scope, before }),
  });
  if (!response.ok) {
    throw new Error(`Mark older stories read failed (${response.status})`);
  }
  return (await response.json()) as MarkReadBeforeResponse;
}
