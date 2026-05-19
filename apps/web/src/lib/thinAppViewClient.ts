import type { OAuthSession } from "@atproto/oauth-client-browser";

import {
  repoAndPublicationFilterFromPubId,
  type EntryListItem,
} from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";

const DEFAULT_GATEWAY =
  process.env.NEXT_PUBLIC_SOCIALWIRE_API_URL ?? "https://api.thesocialwire.app";

export function isThinAppViewEnabled(): boolean {
  return process.env.NEXT_PUBLIC_USE_THIN_APPVIEW === "true";
}

function gatewayBaseUrl(): string {
  return DEFAULT_GATEWAY.replace(/\/$/, "");
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
  cursor?: string;
  limit?: number;
  filter?: ArticleListFilter;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<AppViewEntriesPage> {
  const { publicationKey, cursor, limit = 50, filter = "all", oauthSession, signal } =
    args;
  const { repoDid, publicationAtUri } =
    repoAndPublicationFilterFromPubId(publicationKey);

  const params = new URLSearchParams({
    authorDid: repoDid,
    filter,
    limit: String(limit),
  });
  if (publicationAtUri) params.set("publicationAtUri", publicationAtUri);
  if (cursor) params.set("cursor", cursor);

  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/entries?${params.toString()}`,
    { method: "GET", signal }
  );
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
