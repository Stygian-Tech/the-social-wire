import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import type { PublicationAppViewScope } from "@/lib/publicationProjectionClient";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export function isThinAppViewEnabled(): boolean {
  return process.env.NEXT_PUBLIC_USE_THIN_APPVIEW !== "false";
}

export type AppViewEntriesPage = {
  entries: EntryListItem[];
  cursor?: string;
};

export async function listEntriesFromAppView(args: {
  publicationKey: string;
  appViewScope: PublicationAppViewScope;
  cursor?: string;
  limit?: number;
  maxEntries?: number;
  filter?: ArticleListFilter;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<AppViewEntriesPage> {
  const {
    appViewScope,
    cursor,
    limit = 50,
    maxEntries,
    filter = "all",
    oauthSession,
    signal,
  } = args;

  const { authorDid, publicationAtUri, publicationScopeAtUris, publicationSiteUrls } =
    appViewScope;

  const params = new URLSearchParams({
    authorDid,
    filter,
    limit: String(limit),
  });
  if (typeof maxEntries === "number") {
    params.set("maxEntries", String(maxEntries));
  } else if (cursor) {
    params.set("cursor", cursor);
  }
  if (publicationAtUri) {
    params.set("publicationAtUri", publicationAtUri);
  }
  if (publicationSiteUrls.length > 0) {
    params.set("publicationSiteUrls", publicationSiteUrls.join(","));
  }
  if (publicationScopeAtUris.length > 0) {
    params.set("publicationScopeAtUris", publicationScopeAtUris.join(","));
  }

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

export async function getEntryFromAppView(
  oauthSession: OAuthSession,
  entryId: string,
  signal?: AbortSignal
): Promise<EntryDetail | null> {
  const params = new URLSearchParams({ entryId });
  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/entry?${params.toString()}`,
    { method: "GET", signal }
  );
  if (res.status === 404) {
    return null;
  }
  if (!res.ok) {
    throw new Error(`Thin AppView entry detail failed (${res.status})`);
  }
  const json = (await res.json()) as {
    entryId: string;
    title: string;
    summary?: string;
    publishedAt: string;
    thumbnailUrl?: string;
    contentHtml?: string;
  };
  return {
    entryId: json.entryId,
    title: json.title,
    publishedAt: json.publishedAt,
    contentHtml: json.contentHtml ?? json.summary ?? "",
  };
}

export async function fetchAppViewUnreadCounts(
  oauthSession: OAuthSession,
  publicationIds: string[],
  signal?: AbortSignal
): Promise<Record<string, number>> {
  if (publicationIds.length === 0) return {};
  const params = new URLSearchParams({
    publicationIds: publicationIds.join(","),
  });
  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/unread-counts?${params.toString()}`,
    { method: "GET", signal }
  );
  if (res.status === 404) {
    return {};
  }
  if (!res.ok) {
    throw new Error(`Thin AppView unread counts failed (${res.status})`);
  }
  const json = (await res.json()) as {
    counts?: Record<string, number>;
  };
  return json.counts ?? {};
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
    throw new Error(`Thin AppView read-mark delete failed (${res.status}`);
  }
}

export async function enrollAuthorsInAppView(
  oauthSession: OAuthSession,
  authorDids: string[],
  feedUrls: string[] = []
): Promise<void> {
  if (authorDids.length === 0 && feedUrls.length === 0) return;
  const res = await gatewayFetch(oauthSession, "/v1/appview/enroll", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ authorDids, feedUrls }),
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
