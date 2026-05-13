"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { usePDSClient } from "./usePDSClient";
import { useAuth } from "./useAuth";
import {
  discoverPublications,
  type DiscoveredPublication,
} from "@/lib/atprotoClient";

export type { DiscoveredPublication };

export const PUB_PREFS_QUERY_KEY = ["publicationPrefs"] as const;
export const DISCOVERY_QUERY_KEY = (did: string) =>
  ["discovery", did] as const;

// ── Publication prefs ─────────────────────────────────────────────────────────

/**
 * Returns the user's publication preferences from their PDS.
 */
export function usePublicationPrefs() {
  const client = usePDSClient();
  return useQuery({
    queryKey: PUB_PREFS_QUERY_KEY,
    queryFn: () => client!.listPublicationPrefs(),
    enabled: !!client,
    staleTime: 30_000,
  });
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/**
 * Returns all publications discovered from the user's follow graph.
 */
export function useDiscovery() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;
  const qc = useQueryClient();

  return useQuery({
    queryKey: DISCOVERY_QUERY_KEY(did ?? ""),
    queryFn: async ({ signal }): Promise<DiscoveredPublication[]> => {
      const oauthSession = getOAuthSession();
      if (!did || !oauthSession) return [];
      return discoverPublications(did, oauthSession, {
        signal,
        onProgress: (list) =>
          qc.setQueryData(DISCOVERY_QUERY_KEY(did), list),
      });
    },
    enabled: !!did && !!session,
    /** Long TTL — hydrated from localStorage; user refreshes explicitly via sidebar control. */
    staleTime: 1000 * 60 * 60 * 6,
    gcTime: 1000 * 60 * 60 * 24 * 7,
    refetchOnWindowFocus: false,
  });
}

/**
 * Re-runs discovery by invalidating the cached results, triggering a fresh fetch.
 */
export function useRefreshDiscovery() {
  const { session, getOAuthSession } = useAuth();
  const did = session?.did ?? null;
  const qc = useQueryClient();

  return useMutation({
    mutationFn: async (): Promise<DiscoveredPublication[]> => {
      const oauthSession = getOAuthSession();
      if (!did || !oauthSession) throw new Error("Not authenticated");
      return discoverPublications(did, oauthSession, {
        onProgress: (list) =>
          qc.setQueryData(DISCOVERY_QUERY_KEY(did), list),
      });
    },
  });
}

// ── Publication prefs mutations ───────────────────────────────────────────────

export function useSetPublicationFolder() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({
      publicationId,
      folderId,
      existingRkey,
    }: {
      publicationId: string;
      folderId: string | null;
      existingRkey?: string;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      return client.upsertPublicationPrefs(
        publicationId,
        { folderId },
        existingRkey
      );
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY }),
  });
}

export function useHidePublication() {
  const client = usePDSClient();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({
      publicationId,
      hidden,
      existingRkey,
    }: {
      publicationId: string;
      hidden: boolean;
      existingRkey?: string;
    }) => {
      if (!client) throw new Error("No PDS client — not signed in");
      return client.upsertPublicationPrefs(
        publicationId,
        { hidden },
        existingRkey
      );
    },
    onSuccess: () => qc.invalidateQueries({ queryKey: PUB_PREFS_QUERY_KEY }),
  });
}
