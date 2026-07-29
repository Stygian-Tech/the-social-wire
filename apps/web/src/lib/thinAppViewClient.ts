import type { OAuthSession } from "@atproto/oauth-client-browser";

import type { EntryListItem, EntryDetail } from "@/lib/atprotoClient";
import type { ArticleListFilter } from "@/lib/entryArticleFilter";
import type {
  PublicationAppViewScope,
  UnreadCountsAccuracy,
} from "@/lib/publicationProjectionClient";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";

export function isThinAppViewEnabled(): boolean {
  return process.env.NEXT_PUBLIC_USE_THIN_APPVIEW !== "false";
}

export type AppViewEntriesPage = {
  entries: EntryListItem[];
  cursor?: string;
};

export type AggregateAppViewFeed = {
  kind: "subscribed" | "following" | "folder" | "publication";
  id?: string;
};

export type AppViewUnreadCountsResponse = {
  counts: Record<string, number>;
  generation?: number;
  accuracy?: UnreadCountsAccuracy;
  countedAt?: string;
};

export class AppViewRequestError extends Error {
  readonly status: number;
  readonly requestId?: string;
  readonly retryable: boolean;

  constructor(args: {
    message: string;
    status: number;
    requestId?: string;
    retryable?: boolean;
  }) {
    super(args.message);
    this.name = "AppViewRequestError";
    this.status = args.status;
    this.requestId = args.requestId;
    this.retryable = args.retryable === true;
  }
}

export function shouldRetryAppViewRequest(
  failureCount: number,
  error: unknown
): boolean {
  return (
    failureCount < 1 &&
    error instanceof AppViewRequestError &&
    error.retryable
  );
}

async function appViewResponseError(
  res: Response,
  fallback: string
): Promise<AppViewRequestError> {
  const requestId = res.headers.get("X-Request-ID") ?? undefined;
  let message = `${fallback} (${res.status})`;
  let retryable = false;
  try {
    const envelope = (await res.json()) as {
      message?: string;
      requestId?: string;
      retryable?: boolean;
    };
    message = envelope.message?.trim() || message;
    retryable = envelope.retryable === true;
    return new AppViewRequestError({
      message,
      status: res.status,
      requestId: envelope.requestId ?? requestId,
      retryable,
    });
  } catch {
    return new AppViewRequestError({ message, status: res.status, requestId });
  }
}

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
  if (!res.ok) {
    throw await appViewResponseError(res, "Thin AppView entries failed");
  }

  const json = (await res.json()) as {
    entries?: Array<{
      entryId: string;
      title: string;
      summary?: string;
      publishedAt: string;
      thumbnailUrl?: string;
      thumbnailFallbackUrl?: string;
      originalUrl?: string;
      isRead: boolean;
    }>;
    cursor?: string;
  };

  return {
    entries: (json.entries ?? []).map((row) => {
      const originalUrl = row.originalUrl?.trim();
      const normalizedOriginal = originalUrl
        ? normalizeHttpUrlToHttps(originalUrl)
        : undefined;
      return {
        entryId: row.entryId,
        title: row.title,
        summary: row.summary,
        publishedAt: row.publishedAt,
        thumbnailUrl: row.thumbnailUrl,
        thumbnailFallbackUrl: row.thumbnailFallbackUrl,
        isRead: row.isRead,
        ...(normalizedOriginal ? { originalUrl: normalizedOriginal } : {}),
      };
    }),
    cursor: json.cursor,
  };
}

export async function listAggregateFeedFromAppView(args: {
  feed: AggregateAppViewFeed;
  cursor?: string;
  limit?: number;
  filter?: ArticleListFilter;
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<AppViewEntriesPage> {
  const {
    feed,
    cursor,
    limit = 50,
    filter = "all",
    oauthSession,
    signal,
  } = args;
  const params = new URLSearchParams({
    kind: feed.kind,
    filter,
    limit: String(limit),
  });
  if (feed.id) params.set("id", feed.id);
  if (cursor) params.set("cursor", cursor);
  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/feed?${params.toString()}`,
    { method: "GET", signal },
  );
  if (!res.ok) {
    throw await appViewResponseError(res, "Aggregate AppView feed failed");
  }
  const json = (await res.json()) as {
    entries?: Array<{
      entryId: string;
      title: string;
      summary?: string;
      publishedAt: string;
      thumbnailUrl?: string;
      thumbnailFallbackUrl?: string;
      originalUrl?: string;
      publicationId?: string;
      isRead: boolean;
    }>;
    cursor?: string;
  };
  return {
    entries: (json.entries ?? []).map((row) => {
      const normalizedOriginal = row.originalUrl?.trim()
        ? normalizeHttpUrlToHttps(row.originalUrl)
        : undefined;
      return {
        entryId: row.entryId,
        title: row.title,
        summary: row.summary,
        publishedAt: row.publishedAt,
        thumbnailUrl: row.thumbnailUrl,
        thumbnailFallbackUrl: row.thumbnailFallbackUrl,
        publicationId: row.publicationId,
        isRead: row.isRead,
        ...(normalizedOriginal ? { originalUrl: normalizedOriginal } : {}),
      };
    }),
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
    thumbnailFallbackUrl?: string;
    contentHtml?: string;
    originalUrl?: string;
  };
  const originalUrl = json.originalUrl?.trim();
  const normalizedOriginal = originalUrl
    ? normalizeHttpUrlToHttps(originalUrl)
    : undefined;
  return {
    entryId: json.entryId,
    title: json.title,
    summary: json.summary,
    publishedAt: json.publishedAt,
    contentHtml: json.contentHtml ?? json.summary ?? "",
    thumbnailUrl: json.thumbnailUrl,
    thumbnailFallbackUrl: json.thumbnailFallbackUrl,
    ...(normalizedOriginal
      ? { originalUrl: normalizedOriginal, embedUrl: normalizedOriginal }
      : {}),
  };
}

export async function fetchAppViewUnreadCounts(
  oauthSession: OAuthSession,
  publicationIds: string[],
  signal?: AbortSignal
): Promise<AppViewUnreadCountsResponse> {
  if (publicationIds.length === 0) return { counts: {} };
  const params = new URLSearchParams({
    publicationIds: publicationIds.join(","),
  });
  const res = await gatewayFetch(
    oauthSession,
    `/v1/appview/unread-counts?${params.toString()}`,
    { method: "GET", signal }
  );
  if (res.status === 404) {
    return { counts: {} };
  }
  if (!res.ok) {
    throw new Error(`Thin AppView unread counts failed (${res.status})`);
  }
  const json = (await res.json()) as {
    counts?: Record<string, number>;
    generation?: number;
    accuracy?: UnreadCountsAccuracy;
    countedAt?: string;
  };
  return {
    counts: json.counts ?? {},
    generation: json.generation,
    accuracy: json.accuracy,
    countedAt: json.countedAt,
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
