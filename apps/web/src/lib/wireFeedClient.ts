import { feedResponseError } from "@/lib/feedResponseError";
import type { OAuthSession } from "@atproto/oauth-client-browser";

import { createUpstreamDpopProofPool } from "@/lib/latrGatewayUpstreamDpop";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import {
  gatewayBaseUrl,
  gatewayFetch,
} from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";
import type { EntryListItem } from "@/lib/atprotoClient";

export const WIRE_REASON_CODES = [
  "widely_discussed",
  "breaking_story",
  "shared_across_communities",
  "fresh_publication",
  "resurfacing",
] as const;

export const WIRE_PROVENANCE_CODES = [
  "standard_site",
  "recommendation",
  "direct_share",
  "quote",
  "repost",
  "like",
  "rss",
] as const;

export type WireReasonCode = (typeof WIRE_REASON_CODES)[number];
export type WireProvenanceCode = (typeof WIRE_PROVENANCE_CODES)[number];
export type WirePageSource =
  | "ranked"
  | "stale_generation"
  | "simplified_fallback";

export type WireViewerRegion = "outside-us";

export type WireFeedCatalog = {
  enabled: boolean;
  available: boolean;
  title: "The Wire";
  subtitle: string;
  supportedLanguages: string[];
  latestGenerationId?: string;
  generatedAt?: string;
};

export type WireSource = {
  name: string;
  domain: string;
  publication?: string;
  author?: string;
  publicationKey?: string;
  homepageUrl?: string;
  iconUrl?: string;
};

export type WireItem = {
  itemId: string;
  canonicalUrl: string;
  representativeUri?: string;
  title: string;
  summary?: string;
  publishedAt?: string;
  thumbnailUrl?: string;
  source: WireSource;
  reasons: string[];
  provenance: string[];
  /** Non-production ranking diagnostic; omitted by production responses. */
  rankingScore?: number;
  /** Viewer-scoped metadata retained when the Wire layout presents Your Circle. */
  circleItem?: NonNullable<EntryListItem["circleItem"]>;
};

export type WireItemDetail = {
  item: WireItem;
  html?: string;
  embedUrl?: string;
};

export const WIRE_MODERATION_DPOP_HEADER = "X-Wire-Moderation-DPoP";
export const WIRE_MODERATION_PROOF_SPECS = [
  { xrpcMethod: "app.bsky.actor.getPreferences", httpMethod: "GET" },
  { xrpcMethod: "app.bsky.graph.getBlocks", httpMethod: "GET" },
  { xrpcMethod: "app.bsky.graph.getMutes", httpMethod: "GET" },
  { xrpcMethod: "app.bsky.graph.getListMutes", httpMethod: "GET" },
  { xrpcMethod: "app.bsky.graph.getListBlocks", httpMethod: "GET" },
] as const;

export type WirePage = {
  generationId: string;
  generatedAt: string;
  language: string;
  cursor?: string;
  source: WirePageSource;
  degraded: boolean;
  items: WireItem[];
};

export type WireEntriesPage = {
  entries: EntryListItem[];
  cursor?: string;
  generationId: string;
  generatedAt: string;
  language: string;
  source: WirePageSource;
  degraded: boolean;
};

function publicGatewayFetch(path: string, init?: RequestInit): Promise<Response> {
  const normalizedPath = path.startsWith("/") ? path : `/${path}`;
  const headers = new Headers(init?.headers);
  if (!headers.has("Accept")) headers.set("Accept", "application/json");
  return fetch(`${gatewayBaseUrl()}${normalizedPath}`, {
    ...init,
    credentials: "omit",
    headers,
  });
}

export function createWireModerationDpopProofPool(
  oauthSession: OAuthSession,
): Promise<string> {
  return createUpstreamDpopProofPool(oauthSession, [
    ...WIRE_MODERATION_PROOF_SPECS,
  ]);
}

async function discoveryGatewayFetch(args: {
  path: string;
  signal?: AbortSignal;
  oauthSession?: OAuthSession;
  moderationDpopProofPool?: string;
}): Promise<Response> {
  if (!args.oauthSession) {
    return publicGatewayFetch(args.path, { method: "GET", signal: args.signal });
  }
  const moderationDpopProofPool =
    args.moderationDpopProofPool ??
    (await createWireModerationDpopProofPool(args.oauthSession));
  return gatewayFetch(args.oauthSession, args.path, {
    method: "GET",
    signal: args.signal,
    headers: {
      [WIRE_MODERATION_DPOP_HEADER]: moderationDpopProofPool,
    },
  });
}

const publicResponseError = feedResponseError;

function normalizeHttpsUrl(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? normalizeHttpUrlToHttps(trimmed) : undefined;
}

function isWireReasonCode(value: string): value is WireReasonCode {
  return (WIRE_REASON_CODES as readonly string[]).includes(value);
}

function isWireProvenanceCode(value: string): value is WireProvenanceCode {
  return (WIRE_PROVENANCE_CODES as readonly string[]).includes(value);
}

export function wireReasonLabel(reason: string): string | null {
  if (!isWireReasonCode(reason)) return null;
  switch (reason) {
    case "widely_discussed":
      return "Widely Discussed";
    case "breaking_story":
      return "Breaking Story";
    case "shared_across_communities":
      return "Across Communities";
    case "fresh_publication":
      return "Fresh Publication";
    case "resurfacing":
      return "Resurfacing";
  }
}

export function wireProvenanceLabel(provenance: string): string | null {
  if (!isWireProvenanceCode(provenance)) return null;
  switch (provenance) {
    case "standard_site":
      return "Published on Standard.site";
    case "recommendation":
      return "Recommended";
    case "direct_share":
      return "Directly Shared";
    case "quote":
      return "Quoted";
    case "repost":
      return "Reposted";
    case "like":
      return "Liked";
    case "rss":
      return "From RSS";
  }
}

export function wireItemToEntryListItem(
  item: WireItem,
  generatedAt: string,
): EntryListItem {
  const representativeUri = item.representativeUri?.trim();
  return {
    // Use the representative content record as the social/save subject when one
    // exists. The stable The Wire item id remains available for pagination and
    // getWireItem lookups.
    entryId: representativeUri || item.itemId,
    title: item.title,
    summary: item.summary,
    publishedAt: item.publishedAt ?? generatedAt,
    thumbnailUrl: normalizeHttpsUrl(item.thumbnailUrl),
    originalUrl: normalizeHttpsUrl(item.canonicalUrl),
    wireItem: {
      itemId: item.itemId,
      representativeUri,
      source: {
        ...item.source,
        homepageUrl: normalizeHttpsUrl(item.source.homepageUrl),
        iconUrl: normalizeHttpsUrl(item.source.iconUrl),
      },
      reasons: item.reasons.filter(isWireReasonCode).slice(0, 2),
      provenance: item.provenance.filter(isWireProvenanceCode),
      publishedAt: item.publishedAt,
      rankingScore: item.rankingScore,
    },
    circleItem: item.circleItem,
  };
}

export function wirePageToEntriesPage(page: WirePage): WireEntriesPage {
  return {
    entries: page.items.map((item) =>
      wireItemToEntryListItem(item, page.generatedAt),
    ),
    cursor: page.cursor,
    generationId: page.generationId,
    generatedAt: page.generatedAt,
    language: page.language,
    source: page.source,
    degraded: page.degraded,
  };
}

export async function getWireFeedCatalog(
  signal?: AbortSignal,
): Promise<WireFeedCatalog> {
  if (process.env.NEXT_PUBLIC_USE_DUMMY_DATA === "true") {
    return {
      enabled: true,
      available: true,
      title: "The Wire",
      subtitle: "Important stories across the social web",
      supportedLanguages: ["en"],
      latestGenerationId: "00000000-0000-4000-8000-000000000001",
      generatedAt: "2026-08-21T22:00:00.000Z",
    };
  }
  const response = await publicGatewayFetch(socialWireXrpc.getFeedCatalog, {
    method: "GET",
    signal,
  });
  if (!response.ok) {
    throw await publicResponseError(response, "Feed catalog failed");
  }
  return (await response.json()) as WireFeedCatalog;
}

export async function getWire(args: {
  cursor?: string;
  language?: string;
  limit?: number;
  signal?: AbortSignal;
  oauthSession?: OAuthSession;
  moderationDpopProofPool?: string;
} = {}): Promise<WirePage> {
  const params = new URLSearchParams();
  if (args.cursor) params.set("cursor", args.cursor);
  if (args.language) params.set("lang", args.language);
  if (args.limit != null) params.set("limit", String(args.limit));
  const query = params.size > 0 ? `?${params.toString()}` : "";
  const response = await discoveryGatewayFetch({
    path: `${socialWireXrpc.getWire}${query}`,
    signal: args.signal,
    oauthSession: args.oauthSession,
    moderationDpopProofPool: args.moderationDpopProofPool,
  });
  if (!response.ok) {
    throw await publicResponseError(response, "The Wire failed");
  }
  return (await response.json()) as WirePage;
}

export async function getWireItem(
  itemId: string,
  options: {
    signal?: AbortSignal;
    oauthSession?: OAuthSession;
    moderationDpopProofPool?: string;
  } = {},
): Promise<WireItemDetail | null> {
  const params = new URLSearchParams({ itemId });
  const response = await discoveryGatewayFetch({
    path: `${socialWireXrpc.getWireItem}?${params.toString()}`,
    signal: options.signal,
    oauthSession: options.oauthSession,
    moderationDpopProofPool: options.moderationDpopProofPool,
  });
  if (response.status === 404) return null;
  if (!response.ok) {
    throw await publicResponseError(response, "The Wire item failed");
  }
  return (await response.json()) as WireItemDetail;
}

export function selectWireLanguage(
  supportedLanguages: readonly string[],
  requestedLanguages: readonly string[] =
    typeof navigator === "undefined"
      ? []
      : navigator.languages.length > 0
        ? navigator.languages
        : navigator.language
          ? [navigator.language]
          : [],
): string | undefined {
  const supported = new Map(
    supportedLanguages
      .map((language) => language.trim())
      .filter(Boolean)
      .map((language) => [language.toLowerCase(), language]),
  );
  let preferredPrimaryLanguage: string | undefined;
  for (const requested of requestedLanguages) {
    const normalized = requested.trim().replaceAll("_", "-");
    const primary = normalized.split("-")[0]?.toLowerCase();
    if (!primary || !/^[a-z]{2,8}$/.test(primary)) continue;
    preferredPrimaryLanguage ??= primary;

    const exact = supported.get(normalized.toLowerCase());
    if (exact) return exact;
    const baseMatch = [...supported.entries()].find(
      ([candidate]) =>
        candidate === primary || candidate.startsWith(`${primary}-`),
    );
    if (baseMatch) return baseMatch[1];
  }

  // A missing localized generation must not silently opt the viewer into
  // the multilingual global edition. The AppView accepts a coarse language
  // and serves an exact-language fallback (including an honest empty page).
  return preferredPrimaryLanguage;
}

export function selectWireViewerRegion(
  requestedLanguages: readonly string[] =
    typeof navigator === "undefined"
      ? []
      : navigator.languages.length > 0
        ? navigator.languages
        : navigator.language
          ? [navigator.language]
          : [],
): WireViewerRegion | undefined {
  for (const requested of requestedLanguages) {
    const segments = requested.trim().replaceAll("_", "-").split("-");
    if (!/^[a-z]{2,8}$/i.test(segments[0] ?? "")) continue;
    for (const segment of segments.slice(1)) {
      if (segment.toLowerCase() === "u" || segment.toLowerCase() === "x") break;
      if (!/^(?:[a-z]{2}|\d{3})$/i.test(segment)) continue;
      return segment.toUpperCase() === "US" ? undefined : "outside-us";
    }
  }
  return undefined;
}
