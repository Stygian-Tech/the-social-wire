import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { DiscoveredPublication } from "@/lib/atprotoClient";
import { enrollAuthorsInAppView, isThinAppViewEnabled } from "@/lib/thinAppViewClient";

export type PublicationAppViewScope = {
  authorDid: string;
  publicationAtUri: string | null;
  publicationScopeAtUris: string[];
  publicationSiteUrls: string[];
};

export type SidebarPublicationRow = DiscoveredPublication & {
  appViewScope: PublicationAppViewScope;
};

export type PublicationSidebarProjection = {
  viewerDid: string;
  folders: Array<{ uri: string; rkey: string; value: Record<string, unknown> }>;
  publicationPrefs: Array<{
    uri: string;
    publicationId: string;
    value: Record<string, unknown>;
  }>;
  allPublicationRows: SidebarPublicationRow[];
  myPublications: SidebarPublicationRow[];
  subscribedUnfoldered: SidebarPublicationRow[];
  followingTabPublications: SidebarPublicationRow[];
  enrollAuthorDids: string[];
  refreshedAt: string;
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

function gatewayBaseUrl(): string {
  return (
    process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL ?? "https://api.thesocialwire.app"
  ).replace(/\/$/, "");
}

async function gatewayFetch(
  oauthSession: OAuthSession,
  path: string,
  init?: RequestInit
): Promise<Response> {
  const url = `${gatewayBaseUrl()}${path.startsWith("/") ? path : `/${path}`}`;
  return oauthSession.fetchHandler(url, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.headers ?? {}),
    },
  });
}

export function isPublicationProjectionEnabled(): boolean {
  return process.env.NEXT_PUBLIC_USE_PUBLICATION_PROJECTION !== "false";
}

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
  return fetchPublicationSidebar(oauthSession, signal);
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
  if (!isThinAppViewEnabled() || !oauthSession || authorDids.length === 0) return;
  void enrollAuthorsInAppView(oauthSession, authorDids).catch(() => {
    /* enrollment is best-effort */
  });
}
