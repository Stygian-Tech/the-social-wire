import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { enrollAuthorsInAppView } from "@/lib/thinAppViewClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export type PublicationAppViewScope = {
  authorDid: string;
  publicationAtUri: string | null;
  publicationScopeAtUris: string[];
  publicationSiteUrls: string[];
};

export type SidebarPublicationRow = DiscoveredPublication & {
  appViewScope: PublicationAppViewScope;
  unreadCount?: number;
};

export type PublicationFolderSection = {
  folderRkey: string;
  folderUri: string;
  publications: SidebarPublicationRow[];
};

export type PublicationSidebarProjection = {
  viewerDid: string;
  folders: Array<{ uri: string; rkey: string; value: Record<string, unknown> }>;
  publicationPrefs: Array<{
    uri: string;
    publicationId: string;
    value: Record<string, unknown>;
  }>;
  /** Server-grouped folder sections when provided by gateway projection. */
  folderSections?: PublicationFolderSection[];
  allPublicationRows: SidebarPublicationRow[];
  myPublications: SidebarPublicationRow[];
  subscribedUnfoldered: SidebarPublicationRow[];
  followingTabPublications: SidebarPublicationRow[];
  enrollAuthorDids: string[];
  refreshedAt: string;
  unreadCountsByPublicationId?: Record<string, number>;
};

export type ResolveAddPublicationPayload =
  | { kind: "standard-site"; publicationAtUri: string }
  | {
      kind: "rss";
      feedUrl: string;
      title?: string;
      siteUrl?: string;
      feedIconUrl?: string;
    };

export type GatewayFolderWriteInput = {
  name: string;
  icon?: string;
  iconImage?: string;
  sortOrder?: number;
};

export type GatewayFolderUpdateInput = Partial<GatewayFolderWriteInput>;

export type GatewayPublicationPrefsWriteInput = {
  publicationId: string;
  folderId?: string | null;
  sortOrder?: number;
  hidden?: boolean;
  existingRkey?: string;
};

export type GatewayPublicationSubscriptionWriteInput = {
  publication: string;
};

export type GatewayRssSubscriptionWriteInput = {
  feedUrl: string;
  title?: string;
  siteUrl?: string;
};

export type GatewayMarkAllReadScope =
  | { kind: "publication"; publicationId: string }
  | { kind: "folder"; folderRkey: string }
  | { kind: "subscribed" }
  | { kind: "following" };

export async function fetchPublicationSidebar(
  oauthSession: OAuthSession,
  signal?: AbortSignal
): Promise<PublicationSidebarProjection> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/sidebar", {
    method: "GET",
    signal,
  });
  if (!res.ok) {
    throw new Error(`Publication sidebar failed (${res.status})`);
  }
  return (await res.json()) as PublicationSidebarProjection;
}

export async function refreshPublicationSidebar(
  oauthSession: OAuthSession,
  signal?: AbortSignal
): Promise<PublicationSidebarProjection> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/refresh", {
    method: "POST",
    signal,
  });
  if (!res.ok) {
    throw new Error(`Publication refresh failed (${res.status})`);
  }
  return (await res.json()) as PublicationSidebarProjection;
}

export async function resolveAddPublicationOnGateway(
  oauthSession: OAuthSession,
  input: string,
  signal?: AbortSignal
): Promise<{ result?: ResolveAddPublicationPayload; error?: string }> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/resolve", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ input }),
    signal,
  });
  if (!res.ok) {
    throw new Error(`Publication resolve failed (${res.status})`);
  }
  const json = (await res.json()) as {
    result?: ResolveAddPublicationPayload;
    error?: string | null;
  };
  return {
    result: json.result,
    error: json.error ?? undefined,
  };
}

export async function createFolderOnGateway(
  oauthSession: OAuthSession,
  input: GatewayFolderWriteInput
): Promise<{ uri: string; rkey: string }> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/folders", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(`Create folder failed (${res.status})`);
  }
  return (await res.json()) as { uri: string; rkey: string };
}

export async function updateFolderOnGateway(
  oauthSession: OAuthSession,
  rkey: string,
  input: GatewayFolderUpdateInput
): Promise<void> {
  const res = await gatewayFetch(
    oauthSession,
    `/v1/publications/folders/${encodeURIComponent(rkey)}`,
    {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(input),
    }
  );
  if (!res.ok) {
    throw new Error(`Update folder failed (${res.status})`);
  }
}

export async function deleteFolderOnGateway(
  oauthSession: OAuthSession,
  rkey: string
): Promise<void> {
  const res = await gatewayFetch(
    oauthSession,
    `/v1/publications/folders/${encodeURIComponent(rkey)}`,
    { method: "DELETE" }
  );
  if (!res.ok) {
    throw new Error(`Delete folder failed (${res.status})`);
  }
}

export async function upsertPublicationPrefsOnGateway(
  oauthSession: OAuthSession,
  input: GatewayPublicationPrefsWriteInput
): Promise<{ uri: string; rkey: string }> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/prefs", {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(`Publication prefs upsert failed (${res.status})`);
  }
  return (await res.json()) as { uri: string; rkey: string };
}

export async function createPublicationSubscriptionOnGateway(
  oauthSession: OAuthSession,
  input: GatewayPublicationSubscriptionWriteInput
): Promise<{ uri: string; rkey: string }> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(`Create subscription failed (${res.status})`);
  }
  return (await res.json()) as { uri: string; rkey: string };
}

export async function deletePublicationSubscriptionOnGateway(
  oauthSession: OAuthSession,
  rkey: string
): Promise<void> {
  const res = await gatewayFetch(
    oauthSession,
    `/v1/publications/subscriptions/${encodeURIComponent(rkey)}`,
    { method: "DELETE" }
  );
  if (!res.ok) {
    throw new Error(`Delete subscription failed (${res.status})`);
  }
}

export async function createRssSubscriptionOnGateway(
  oauthSession: OAuthSession,
  input: GatewayRssSubscriptionWriteInput
): Promise<{ uri: string; rkey: string }> {
  const res = await gatewayFetch(oauthSession, "/v1/publications/rss-subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(input),
  });
  if (!res.ok) {
    throw new Error(`Create RSS subscription failed (${res.status})`);
  }
  return (await res.json()) as { uri: string; rkey: string };
}

export async function deleteRssSubscriptionOnGateway(
  oauthSession: OAuthSession,
  rkey: string
): Promise<void> {
  const res = await gatewayFetch(
    oauthSession,
    `/v1/publications/rss-subscriptions/${encodeURIComponent(rkey)}`,
    { method: "DELETE" }
  );
  if (!res.ok) {
    throw new Error(`Delete RSS subscription failed (${res.status})`);
  }
}

export async function markAllReadOnGateway(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope
): Promise<{ marked: number }> {
  const res = await gatewayFetch(oauthSession, "/v1/appview/mark-all-read", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ scope }),
  });
  if (!res.ok) {
    throw new Error(`Mark all read failed (${res.status})`);
  }
  return (await res.json()) as { marked: number };
}

export function sidebarRowToDiscoveredPublication(
  row: SidebarPublicationRow
): DiscoveredPublication {
  return {
    publicationId: row.publicationId,
    subscriptionPublicationId: row.subscriptionPublicationId,
    authorDid: row.authorDid,
    authorHandle: row.authorHandle ?? row.authorDid,
    title: row.title,
    iconUrl: row.iconUrl,
    avatarUrl: row.avatarUrl,
    discoveredAt: row.discoveredAt,
  };
}

export function unreadCountsMapFromProjection(
  projection: PublicationSidebarProjection | undefined
): Map<string, number> {
  const map = new Map<string, number>();
  if (!projection) return map;

  const applyCount = (publicationId: string, count: number | undefined) => {
    if (count == null || count <= 0) return;
    map.set(publicationId, count);
  };

  for (const row of projection.allPublicationRows) {
    const embedded = row.unreadCount;
    const fromRecord = projection.unreadCountsByPublicationId?.[row.publicationId];
    applyCount(row.publicationId, embedded ?? fromRecord);
  }

  if (projection.unreadCountsByPublicationId) {
    for (const [publicationId, count] of Object.entries(
      projection.unreadCountsByPublicationId
    )) {
      if (!map.has(publicationId)) {
        applyCount(publicationId, count);
      }
    }
  }

  return map;
}

/** True when sidebar rows already include per-publication unread counts from the server. */
export function sidebarIncludesUnreadCounts(
  projection: PublicationSidebarProjection | undefined
): boolean {
  if (!projection) return false;
  return projection.allPublicationRows.some((row) => row.unreadCount != null);
}

export function appViewScopeFromProjection(
  projection: PublicationSidebarProjection | undefined,
  publicationKey: string
): PublicationAppViewScope | undefined {
  if (!projection) return undefined;
  const row = projection.allPublicationRows.find(
    (r) => r.publicationId === publicationKey
  );
  return row?.appViewScope;
}

export function maybeEnrollProjectionAuthors(
  oauthSession: OAuthSession | null,
  authorDids: string[]
): void {
  if (!oauthSession || authorDids.length === 0) return;
  void enrollAuthorsInAppView(oauthSession, authorDids).catch(() => {
    /* enrollment is best-effort */
  });
}
