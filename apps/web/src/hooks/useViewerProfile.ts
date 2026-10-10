"use client";

import { Agent } from "@atproto/api";
import { useQuery } from "@tanstack/react-query";
import { useAuth } from "./useAuth";
import {
  BSKY_APPVIEW_PUBLIC,
  createOAuthAgent,
} from "@/lib/atprotoClient";
import {
  dummyViewerProfile,
  isDummyReaderDataEnabled,
} from "@/lib/dummyReaderData";

export const VIEWER_PROFILE_QUERY_KEY = (did: string) =>
  ["viewerProfile", did] as const;

/** Profile fields sourced from AppView; repository fallback supplies only available text. */
export type ViewerProfileSlice = {
  did: string;
  handle?: string;
  displayName?: string;
  avatar?: string;
  description?: string;
  banner?: string;
  followersCount?: number;
  followsCount?: number;
  postsCount?: number;
};

/**
 * Loads the signed-in user's Bluesky-facing profile (avatar, display name, handle).
 *
 * OAuth access tokens from ATProto are typically audience-bound to the user's **PDS**.
 * Sending them on App View XRPC often yields 401. Use the **public** App View host for
 * `app.bsky.actor.getProfile` without Authorization for indexed accounts.
 *
 * Fallback: read `app.bsky.actor.profile` on the user's repo via {@link createOAuthAgent}
 * (correct audience → PDS).
 */
export function useViewerProfile() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;
  const dummyReaderDataEnabled = isDummyReaderDataEnabled();

  return useQuery({
    queryKey: VIEWER_PROFILE_QUERY_KEY(did ?? ""),
    queryFn: async (): Promise<ViewerProfileSlice | null> => {
      if (!did) return null;
      if (dummyReaderDataEnabled) return dummyViewerProfile;

      const appViewAgent = new Agent(BSKY_APPVIEW_PUBLIC);
      try {
        const res = await appViewAgent.api.app.bsky.actor.getProfile({
          actor: did,
        });
        const d = res.data;
        return {
          did: d.did,
          handle: d.handle,
          displayName: d.displayName,
          avatar: d.avatar,
          description: d.description,
          banner: d.banner,
          followersCount: d.followersCount,
          followsCount: d.followsCount,
          postsCount: d.postsCount,
        };
      } catch {
        const oauthSession = getOAuthSession();
        if (!oauthSession) return null;
        const pdsAgent = createOAuthAgent(oauthSession);
        const rec = await pdsAgent.api.com.atproto.repo.getRecord({
          repo: did,
          collection: "app.bsky.actor.profile",
          rkey: "self",
        });
        const val = rec.data.value as Record<string, unknown>;
        const str = (v: unknown): string | undefined =>
          typeof v === "string" ? v : undefined;
        return {
          did,
          handle: did,
          displayName: str(val.displayName),
          description: str(val.description),
        };
      }
    },
    enabled: !!did,
    staleTime: 5 * 60_000,
  });
}
