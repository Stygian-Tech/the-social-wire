import type { OAuthSession } from "@atproto/oauth-client-browser";

import { createUpstreamDpopProofPool } from "@/lib/latrGatewayUpstreamDpop";
import {
  gatewayBaseUrl,
  gatewayFetch,
} from "@/lib/socialWireGatewayClient";
import { socialWireXrpc } from "@/lib/socialWireXrpc";
import {
  WIRE_MODERATION_DPOP_HEADER,
  WIRE_MODERATION_PROOF_SPECS,
  type WireItem,
  type WirePageSource,
  type WireSource,
  type WireViewerRegion,
} from "@/lib/wireFeedClient";
import { dummyWireEdition } from "@/lib/dummyWireEditionData";
import { isDummyReaderDataEnabled } from "@/lib/dummyReaderData";

export function isWireNewsEditionEnabled(): boolean {
  return (
    process.env.NEXT_PUBLIC_WIRE_NEWS_EDITION_ENABLED === "true" ||
    isDummyReaderDataEnabled()
  );
}

export type WirePublicationSpotlight = {
  id: string;
  publication: WireSource;
  storyIds: string[];
};

export type WireStoryRail = {
  id: string;
  title: string;
  storyIds: string[];
};

export type WireTalkedAboutPerson = {
  did: string;
  handle: string;
  displayName: string;
  avatarUrl?: string;
  description?: string;
};

export type WireEditionPage = {
  editionVersion: string;
  generationId: string;
  generatedAt: string;
  language: string;
  source: WirePageSource;
  degraded: boolean;
  stories: WireItem[];
  topStoryIds: string[];
  publicationSpotlights: WirePublicationSpotlight[];
  storyRails: WireStoryRail[];
  people: WireTalkedAboutPerson[];
  trendingStoryIds: string[];
  moreCursor?: string;
};

function publicGatewayFetch(path: string, signal?: AbortSignal): Promise<Response> {
  return fetch(`${gatewayBaseUrl()}${path}`, {
    method: "GET",
    credentials: "omit",
    signal,
    headers: { Accept: "application/json" },
  });
}

async function responseError(response: Response): Promise<Error> {
  try {
    const body = (await response.json()) as { message?: string };
    return new Error(
      body.message?.trim() || `The Wire edition failed (${response.status})`,
    );
  } catch {
    return new Error(`The Wire edition failed (${response.status})`);
  }
}

export async function getWireEdition(args: {
  language?: string;
  region?: WireViewerRegion;
  signal?: AbortSignal;
  oauthSession?: OAuthSession;
  moderationDpopProofPool?: string;
} = {}): Promise<WireEditionPage> {
  if (process.env.NEXT_PUBLIC_USE_DUMMY_DATA === "true") return dummyWireEdition();
  const params = new URLSearchParams();
  if (args.language) params.set("lang", args.language);
  if (args.region) params.set("region", args.region);
  const query = params.size > 0 ? `?${params.toString()}` : "";
  const path = `${socialWireXrpc.getWireEdition}${query}`;

  let response: Response;
  if (args.oauthSession) {
    const proofPool =
      args.moderationDpopProofPool ??
      (await createUpstreamDpopProofPool(args.oauthSession, [
        ...WIRE_MODERATION_PROOF_SPECS,
      ]));
    response = await gatewayFetch(args.oauthSession, path, {
      method: "GET",
      signal: args.signal,
      headers: { [WIRE_MODERATION_DPOP_HEADER]: proofPool },
    });
  } else {
    response = await publicGatewayFetch(path, args.signal);
  }

  if (!response.ok) throw await responseError(response);
  return (await response.json()) as WireEditionPage;
}
