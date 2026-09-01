import type { OAuthSession } from "@atproto/oauth-client-browser";

import { createUpstreamDpopProofPool } from "@/lib/latrGatewayUpstreamDpop";
import { normalizeHttpUrlToHttps } from "@/lib/publicResourceUrl";
import { gatewayFetch } from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";
import type { EntryListItem } from "@/lib/atprotoClient";
import {
  WIRE_MODERATION_PROOF_SPECS,
  type WirePageSource,
  type WireSource,
} from "@/lib/wireFeedClient";

export const CIRCLE_GRAPH_DPOP_HEADER = "X-Circle-Graph-DPoP";
export const CIRCLE_GRAPH_PROOF_SPECS = [
  ...WIRE_MODERATION_PROOF_SPECS,
  { xrpcMethod: "com.atproto.repo.listRecords", httpMethod: "GET" },
] as const;

export type CircleFeedCatalog = {
  enabled: boolean;
  available: boolean;
  title: string;
  subtitle: string;
  supportedLanguages: string[];
  latestGenerationId?: string;
  generatedAt?: string;
};

export type CirclePublicIdentity = {
  did: string;
  handle: string;
  displayName?: string;
  avatarUrl?: string;
};

export type CircleSharer = {
  identity: CirclePublicIdentity;
  relationship: "direct" | "one_hop";
  action: "recommended" | "shared" | "discussed";
  sourceUri: string;
  timestamp: string;
};

export type CircleStory = {
  storyId: string;
  canonicalUrl: string;
  representativeUri?: string;
  title: string;
  summary?: string;
  publishedAt?: string;
  thumbnailUrl?: string;
  source: WireSource;
  reasons: string[];
  discussionCount: number;
  sharerCount: number;
  sharers: CircleSharer[];
};

export type CirclePublicationSpotlight = {
  id: string;
  publication: WireSource;
  storyIds: string[];
};

export type CircleStoryRail = {
  id: string;
  title: string;
  storyIds: string[];
};

export type CircleEditionPage = {
  editionVersion: string;
  generationId: string;
  generatedAt: string;
  language: string;
  source: WirePageSource;
  degraded: boolean;
  stories: CircleStory[];
  topStoryIds: string[];
  publicationSpotlights: CirclePublicationSpotlight[];
  storyRails: CircleStoryRail[];
  trendingStoryIds: string[];
  moreCursor?: string;
};

export type CircleHiddenItemState = {
  storyId: string;
  hidden: boolean;
};

export function circleReasonLabel(reason: string): string | null {
  switch (reason) {
    case "shared_by_following":
    case "shared_by_extended_circle":
      return null;
    case "popular_in_your_circle":
      return "Popular In Your Circle";
    case "discussed_in_your_circle":
      return "Discussed In Your Circle";
    case "fresh_from_your_circle":
      return "Fresh From Your Circle";
    default:
      return null;
  }
}

export function circleCatalogRequest(): {
  path: string;
  init: RequestInit;
} {
  return {
    path: socialWireXrpc.getCircleCatalog,
    init: { method: "GET" },
  };
}

export function circleEditionRequest(args: {
  language?: string;
  cursor?: string;
  signal?: AbortSignal;
  bypassCache?: boolean;
  proofPool: string;
}): { path: string; init: RequestInit } {
  const params = new URLSearchParams();
  if (args.language) params.set("lang", args.language);
  if (args.cursor) params.set("cursor", args.cursor);
  const query = params.size > 0 ? `?${params.toString()}` : "";
  return {
    path: `${socialWireXrpc.getCircleEdition}${query}`,
    init: {
      method: "GET",
      signal: args.signal,
      cache: args.bypassCache ? "no-store" : "default",
      headers: { [CIRCLE_GRAPH_DPOP_HEADER]: args.proofPool },
    },
  };
}

export function circleHiddenItemRequest(args: {
  storyId: string;
  hidden: boolean;
  signal?: AbortSignal;
}): { path: string; init: RequestInit } {
  return {
    path: socialWireXrpc.setCircleItemHidden,
    init: {
      method: "POST",
      signal: args.signal,
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ storyId: args.storyId, hidden: args.hidden }),
    },
  };
}

async function circleResponseError(
  response: Response,
  fallback: string,
): Promise<Error> {
  try {
    const body = (await response.json()) as { message?: string };
    return new Error(body.message?.trim() || `${fallback} (${response.status})`);
  } catch {
    return new Error(`${fallback} (${response.status})`);
  }
}

export async function getCircleCatalog(args: {
  oauthSession: OAuthSession;
  signal?: AbortSignal;
}): Promise<CircleFeedCatalog> {
  const request = circleCatalogRequest();
  const response = await gatewayFetch(
    args.oauthSession,
    request.path,
    { ...request.init, signal: args.signal },
  );
  if (!response.ok) {
    throw await circleResponseError(response, "Your Circle catalog failed");
  }
  return (await response.json()) as CircleFeedCatalog;
}

export async function getCircleEdition(args: {
  oauthSession: OAuthSession;
  language?: string;
  cursor?: string;
  signal?: AbortSignal;
  bypassCache?: boolean;
}): Promise<CircleEditionPage> {
  const proofPool = await createUpstreamDpopProofPool(
    args.oauthSession,
    [...CIRCLE_GRAPH_PROOF_SPECS],
  );
  const request = circleEditionRequest({ ...args, proofPool });
  const response = await gatewayFetch(
    args.oauthSession,
    request.path,
    request.init,
  );
  if (!response.ok) {
    throw await circleResponseError(response, "Your Circle edition failed");
  }
  return (await response.json()) as CircleEditionPage;
}

export async function setCircleItemHidden(args: {
  oauthSession: OAuthSession;
  storyId: string;
  hidden: boolean;
  signal?: AbortSignal;
}): Promise<CircleHiddenItemState> {
  const request = circleHiddenItemRequest(args);
  const response = await gatewayFetch(
    args.oauthSession,
    request.path,
    request.init,
  );
  if (!response.ok) {
    throw await circleResponseError(response, "Your Circle hide state failed");
  }
  return (await response.json()) as CircleHiddenItemState;
}

function normalizedHttpsURL(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed ? normalizeHttpUrlToHttps(trimmed) : undefined;
}

export function circleStoryToEntryListItem(
  story: CircleStory,
  generatedAt: string,
): EntryListItem {
  const representativeUri = story.representativeUri?.trim();
  return {
    entryId: representativeUri || story.storyId,
    title: story.title,
    summary: story.summary,
    publishedAt: story.publishedAt ?? generatedAt,
    thumbnailUrl: normalizedHttpsURL(story.thumbnailUrl),
    originalUrl: normalizedHttpsURL(story.canonicalUrl),
    circleItem: {
      storyId: story.storyId,
      representativeUri,
      source: {
        ...story.source,
        homepageUrl: normalizedHttpsURL(story.source.homepageUrl),
        iconUrl: normalizedHttpsURL(story.source.iconUrl),
      },
      reasons: story.reasons,
      discussionCount: story.discussionCount,
      sharerCount: story.sharerCount,
      sharers: story.sharers,
      publishedAt: story.publishedAt,
    },
  };
}
