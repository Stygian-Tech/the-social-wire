import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  buildPublicationScopeMatch,
  resolvePublicationFilterFromPubId,
  type EntryListItem,
} from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import type { PublicationAppViewScope } from "@/lib/publicationProjectionClient";

export function isThinAppViewEnabled(): boolean {
  return process.env.NEXT_PUBLIC_USE_THIN_APPVIEW === "true";
}

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

export type AppViewEntriesPage = {
  entries: EntryListItem[];
  cursor?: string;
};

export async function listEntriesFromAppView(args: {
  publicationKey: string;
  /** When provided (from `/v1/publications/sidebar`), skips client-side scope derivation. */
  appViewScope?: PublicationAppViewScope;
  cursor?: string;
  limit?: number;
  filter?: ArticleListFilter;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<AppViewEntriesPage> {
  const {
    publicationKey,
    appViewScope,
    cursor,
    limit = 50,
    filter = "all",
    oauthSession,
    signal,
  } = args;

  let authorDid: string;
  let publicationAtUri: string | undefined;
  let scopeAtUris: string[] = [];
  let scopeSiteUrls: string[] = [];

  if (appViewScope) {
    authorDid = appViewScope.authorDid;
    publicationAtUri = appViewScope.publicationAtUri ?? undefined;
    scopeAtUris = appViewScope.publicationScopeAtUris;
    scopeSiteUrls = appViewScope.publicationSiteUrls;
  } else {
    const resolved = await resolvePublicationFilterFromPubId(
      publicationKey,
      oauthSession
    );
    authorDid = resolved.repoDid;
    publicationAtUri = resolved.publicationAtUri;
    if (publicationAtUri) {
      const scope = await buildPublicationScopeMatch(
        publicationAtUri,
        oauthSession
      );
      scopeSiteUrls = [...scope.siteUrlKeys];
      scopeAtUris = [...scope.atUriKeys];
    }
  }

  const params = new URLSearchParams({
    authorDid,
    filter,
    limit: String(limit),
  });
  if (publicationAtUri) {
    params.set("publicationAtUri", publicationAtUri);
  }
  if (scopeSiteUrls.length > 0) {
    params.set("publicationSiteUrls", scopeSiteUrls.join(","));
  }
  if (scopeAtUris.length > 0) {
    params.set("publicationScopeAtUris", scopeAtUris.join(","));
  }
  if (cursor) params.set("cursor", cursor);

  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/entries?${params.toString()}`,
    { method: "GET", signal }
  );
  if (res.status === 404) {
    throw new Error("Thin AppView unavailable");
  }
  if (!res.ok) {
    throw new Error(`Thin AppView entries failed (${res.status})`);
  }

  const json = (await res.json()) as {
    entries?: Array<{
      entryId: string;
      title: string;
      summary?: string;
      publishedAt: string;
      thumbnailUrl?: string;
      thumbnailFallbackUrl?: string;
    }>;
    cursor?: string;
  };

  return {
    entries: (json.entries ?? []).map((row) => ({
      entryId: row.entryId,
      title: row.title,
      summary: row.summary,
      publishedAt: row.publishedAt,
      thumbnailUrl: row.thumbnailUrl,
      thumbnailFallbackUrl: row.thumbnailFallbackUrl,
    })),
    cursor: json.cursor,
  };
}

export async function writeThroughReadMark(
  oauthSession: OAuthSession,
  subjectUri: string,
  readAt: string
): Promise<void> {
  const res = await gatewayFetch(oauthSession, "/v1/appview/read-marks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ subjectUri, readAt }),
  });
  if (!res.ok) {
    throw new Error(`Thin AppView read-mark upsert failed (${res.status})`);
  }
}

export async function writeThroughReadMarkDelete(
  oauthSession: OAuthSession,
  subjectUri: string
): Promise<void> {
  const res = await gatewayFetch(oauthSession, "/v1/appview/read-marks", {
    method: "DELETE",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ subjectUri }),
  });
  if (!res.ok) {
    throw new Error(`Thin AppView read-mark delete failed (${res.status})`);
  }
}

export async function enrollAuthorsInAppView(
  oauthSession: OAuthSession,
  authorDids: string[]
): Promise<void> {
  if (authorDids.length === 0) return;
  const res = await gatewayFetch(oauthSession, "/v1/appview/enroll", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ authorDids }),
  });
  if (!res.ok) {
    throw new Error(`Thin AppView enroll failed (${res.status})`);
  }
}

export async function purgeThinAppViewData(
  oauthSession: OAuthSession
): Promise<void> {
  const res = await gatewayFetch(oauthSession, "/v1/appview/privacy/purge", {
    method: "DELETE",
  });
  if (!res.ok) {
    throw new Error(`Thin AppView purge failed (${res.status})`);
  }
}
