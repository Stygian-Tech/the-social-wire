import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  type DiscoveredPublication,
  normalizeAtRepoParam,
} from "@/lib/atprotoClient";
import { enrollAuthorsInAppView } from "@/lib/thinAppViewClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";

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

export type UnreadCountsAccuracy = "estimated" | "exact" | (string & {});

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
  unreadCountsGeneration?: number;
  unreadCountsAccuracy?: UnreadCountsAccuracy;
  unreadCountsCountedAt?: string;
  sidebarSectionGenerations?: Record<string, number>;
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

export type GatewayMarkAllReadScope =
  | { kind: "publication"; publicationId: string }
  | { kind: "folder"; folderRkey: string }
  | { kind: "subscribed" }
  | { kind: "following" };

export type PublicationSidebarPhase = "full" | "priority" | "folderPublications";

export async function fetchPublicationSidebar(
  oauthSession: OAuthSession,
  options?: { phase?: PublicationSidebarPhase; signal?: AbortSignal }
): Promise<PublicationSidebarProjection> {
  const params = new URLSearchParams();
  if (options?.phase && options.phase !== "full") {
    params.set("phase", options.phase);
  }
  const query = params.toString();
  const res = await gatewayFetch(
    oauthSession,
    query ? `${socialWireXrpc.getSidebar}?${query}` : socialWireXrpc.getSidebar,
    {
      method: "GET",
      signal: options?.signal,
    }
  );
  if (!res.ok) {
    throw new Error(`Publication sidebar failed (${res.status})`);
  }
  return (await res.json()) as PublicationSidebarProjection;
}

/**
 * Drops the viewer's server-side projection caches and returns the rebuilt **priority tier**.
 *
 * Folder sections come back without their publications, and the Following tab may be a carried-over
 * snapshot, because the server pushes full follow-graph discovery into a background pass. Merge the
 * result into the existing projection with `applySidebarPriorityEvent` — replacing a cached
 * projection with this payload wholesale empties every folder in the sidebar.
 */
export async function refreshPublicationSidebar(
  oauthSession: OAuthSession,
  signal?: AbortSignal
): Promise<PublicationSidebarProjection> {
  const res = await gatewayFetch(oauthSession, socialWireXrpc.refreshSidebar, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: "{}",
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
  const res = await gatewayFetch(oauthSession, socialWireXrpc.resolvePublication, {
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

export async function markAllReadOnGateway(
  oauthSession: OAuthSession,
  scope: GatewayMarkAllReadScope
): Promise<GatewayMarkAllReadResponse> {
  const res = await gatewayFetch(oauthSession, socialWireXrpc.markAllRead, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ scope }),
  });
  if (!res.ok) {
    throw new Error(`Mark all read failed (${res.status})`);
  }
  return (await res.json()) as GatewayMarkAllReadResponse;
}

export type GatewayMarkAllReadResponse = {
  marked: number;
  confirmedAt: string;
  boundaries: Array<{
    publicationId: string;
    createdAt: string;
    entryId?: string;
  }>;
  unreadCounts: Record<string, number>;
};

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
    if (count == null || count < 0) return;
    map.set(publicationId, count);
  };

  const recordCount = (
    publicationId: string
  ): number | undefined => {
    const record = projection.unreadCountsByPublicationId;
    if (!record) return undefined;
    const target = normalizeAtRepoParam(publicationId);
    for (const [key, count] of Object.entries(record)) {
      if (normalizeAtRepoParam(key) === target) return count;
    }
    return undefined;
  };

  for (const row of sidebarPublicationRows(projection)) {
    const embedded = row.unreadCount;
    const fromRecord = recordCount(row.publicationId);
    // Prefer the projection record map — it carries optimistic deltas and tab-sync refreshes.
    applyCount(row.publicationId, fromRecord ?? embedded);
  }

  if (projection.unreadCountsByPublicationId) {
    for (const [publicationId, count] of Object.entries(
      projection.unreadCountsByPublicationId
    )) {
      const target = normalizeAtRepoParam(publicationId);
      const alreadyStored = [...map.keys()].some(
        (key) => normalizeAtRepoParam(key) === target
      );
      if (!alreadyStored) {
        applyCount(publicationId, count);
      }
    }
  }

  return map;
}

export function mergeSidebarProjections(
  priority: PublicationSidebarProjection,
  folders: PublicationSidebarProjection | undefined
): PublicationSidebarProjection {
  if (!folders) return priority;

  const rowById = new Map<string, SidebarPublicationRow>();
  for (const row of priority.allPublicationRows) {
    rowById.set(row.publicationId, row);
  }
  for (const row of folders.allPublicationRows) {
    rowById.set(row.publicationId, row);
  }

  return {
    ...priority,
    folderSections: folders.folderSections?.length
      ? folders.folderSections
      : priority.folderSections,
    allPublicationRows: [...rowById.values()],
  };
}

/** True when sidebar rows already include per-publication unread counts from the server. */
export function sidebarIncludesUnreadCounts(
  projection: PublicationSidebarProjection | undefined
): boolean {
  if (!projection) return false;
  return projection.allPublicationRows.some((row) => row.unreadCount != null);
}

export function publicationIdsFromProjection(
  projection: PublicationSidebarProjection
): string[] {
  return sidebarPublicationRows(projection).map((row) => row.publicationId);
}

export function sidebarPublicationRows(
  projection: PublicationSidebarProjection
): SidebarPublicationRow[] {
  const byId = new Map<string, SidebarPublicationRow>();
  const add = (row: SidebarPublicationRow) => {
    byId.set(normalizeAtRepoParam(row.publicationId), row);
  };

  for (const row of projection.allPublicationRows) add(row);
  for (const row of projection.myPublications) add(row);
  for (const row of projection.subscribedUnfoldered) add(row);
  for (const row of projection.followingTabPublications) add(row);
  for (const section of projection.folderSections ?? []) {
    for (const row of section.publications) add(row);
  }

  return [...byId.values()];
}

export function appViewScopeFromProjection(
  projection: PublicationSidebarProjection | undefined,
  publicationKey: string
): PublicationAppViewScope | undefined {
  if (!projection) return undefined;
  const target = normalizeAtRepoParam(publicationKey);
  const row = sidebarPublicationRows(projection).find(
    (r) => normalizeAtRepoParam(r.publicationId) === target
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
